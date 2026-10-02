// CCM1: fixed-point, context-conditioned bit model. Source-only DEV scorer.
// The predictor uses integer state; floating log2 is confined to reporting.
#include "../squash_table.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <iterator>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t Q = 32768;
constexpr uint32_t Backoff = 16;
constexpr size_t Experts = 13;
constexpr size_t MixContexts = 1024;
constexpr uint32_t MatchWindow = 1 << 20;
constexpr uint32_t MaxSource = 1 << 24;

int64_t floor_shift(int64_t value, unsigned shift) {
    if (value >= 0) return value >> shift;
    return -(((-value) + ((int64_t(1) << shift) - 1)) >> shift);
}
uint64_t scramble(uint64_t x) {
    x ^= x >> 30; x *= 0xbf58476d1ce4e5b9ULL;
    x ^= x >> 27; x *= 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}
uint32_t bounded_probability(uint32_t p) { return std::clamp(p, 1u, Q - 1); }

struct Tables {
    std::array<int16_t, Q> stretch{};
    Tables() {
        for (uint32_t p = 1; p < Q; ++p) {
            if (p <= kSquash[0]) { stretch[p] = -2048; continue; }
            if (p >= kSquash[4096]) { stretch[p] = 2048; continue; }
            auto begin = std::begin(kSquash);
            auto end = std::end(kSquash);
            auto it = std::lower_bound(begin, end, p);
            size_t next = size_t(it - begin);
            size_t prior = next - 1;
            size_t selected = uint32_t(p - kSquash[prior]) <= uint32_t(kSquash[next] - p)
                ? prior : next;  // nearest; ties choose lower coordinate
            stretch[p] = int16_t(int(selected) - 2048);
        }
        stretch[0] = -2048;
    }
    uint32_t squash(int32_t z) const {
        return kSquash[std::clamp(z, -2048, 2048) + 2048];
    }
};

struct Key {
    uint64_t a = 0, b = 0;
    uint16_t prefix = 0, aux = 0;
    bool operator==(const Key& other) const {
        return a == other.a && b == other.b && prefix == other.prefix && aux == other.aux;
    }
};
struct Counts { uint16_t zero = 0, one = 0; };
void add_count(Counts& c, bool bit) {
    if (bit) ++c.one; else ++c.zero;
    if (uint32_t(c.zero) + c.one >= 512) {
        c.zero = uint16_t((uint32_t(c.zero) + 1) >> 1);
        c.one = uint16_t((uint32_t(c.one) + 1) >> 1);
    }
}
uint32_t predict_counts(const Counts* c, uint32_t fallback) {
    if (!c) return fallback;
    uint32_t total = uint32_t(c->zero) + c->one;
    return bounded_probability((uint32_t(c->one) * Q + Backoff * fallback) /
                               (total + Backoff));
}
struct WordRun {
    uint64_t lo = 0, hi = 0;
    uint16_t len = 0;
    void clear() { lo = hi = 0; len = 0; }
    void push(uint8_t byte) {
        if (len < 8) lo = (lo << 8) | byte;
        else if (len < 16) hi = (hi << 8) | byte;
        ++len;
    }
};
bool byte_boundary(uint8_t b) {
    if (b <= 32 || b == 127) return true;
    if (b >= 128) return false;
    return b == ',' || b == '.' || b == ';' || b == ':' || b == '!' ||
           b == '?' || b == '\'' || b == '"' || b == '(' || b == ')' ||
           b == '[' || b == ']' || b == '{' || b == '}' || b == '-' || b == '/';
}
struct ScriptState {
    uint8_t script = 7, boundary = 3;
    uint8_t pending = 0;
    uint32_t codepoint = 0, minimum = 0;
    void finish(uint32_t cp, bool valid) {
        if (!valid) { script = 7; boundary = 3; return; }
        if (cp < 128) script = 0;
        else if (cp <= 0x024f) script = 1;
        else if (cp >= 0x0370 && cp <= 0x052f) script = 2;
        else if (cp >= 0x0600 && cp <= 0x08ff) script = 3;
        else if (cp >= 0x3040 && cp <= 0x30ff) script = 4;
        else if (cp >= 0x3400 && cp <= 0x9fff) script = 5;
        else if ((cp >= 0xac00 && cp <= 0xd7af) || (cp >= 0x0900 && cp <= 0x0d7f)) script = 6;
        else script = 7;
        if (cp == ' ' || cp == '\t' || cp == '\r' || cp == '\n' || cp == 0x3000) boundary = 0;
        else if ((cp < 128 && byte_boundary(uint8_t(cp))) ||
                 (cp >= 0x3001 && cp <= 0x303f)) boundary = 1;
        else if (script != 7) boundary = 2;
        else boundary = 3;
    }
    void feed(uint8_t byte) {
        if (pending && byte >= 0x80 && byte <= 0xbf) {
            codepoint = (codepoint << 6) | (byte & 63);
            if (--pending == 0)
                finish(codepoint, codepoint >= minimum && codepoint <= 0x10ffff &&
                                  !(codepoint >= 0xd800 && codepoint <= 0xdfff));
            return;
        }
        if (pending) { pending = 0; finish(0, false); }
        if (byte < 0x80) finish(byte, true);
        else if (byte >= 0xc2 && byte <= 0xdf) { codepoint = byte & 31; pending = 1; minimum = 0x80; }
        else if (byte >= 0xe0 && byte <= 0xef) { codepoint = byte & 15; pending = 2; minimum = 0x800; }
        else if (byte >= 0xf0 && byte <= 0xf4) { codepoint = byte & 7; pending = 3; minimum = 0x10000; }
        else finish(0, false);
    }
};

struct MatchEntry { uint64_t context = 0; uint32_t at = 0, age = 0; bool used = false; };
struct MatchState {
    std::vector<MatchEntry> entries = std::vector<MatchEntry>(4 * (1u << 16));
    std::array<std::array<Counts, 8>, 4> confidence{};
    uint32_t donor = 0, run = 0, clock = 0;
    bool active = false, divergent = false;
    uint64_t replacements = 0, eligible_bytes = 0, matched_bytes = 0;
    size_t bucket(uint64_t history) const { return (scramble(history) & ((1u << 16) - 1)) * 4; }
    unsigned tier() const { return !active ? 0 : run == 0 ? 1 : run < 4 ? 2 : 3; }
    void begin(uint64_t history, uint32_t at) {
        divergent = false;
        if (active && donor < at && at - donor <= MatchWindow) { ++eligible_bytes; return; }
        active = false; run = 0;
        if (at < 8) return;
        size_t first = bucket(history);
        for (size_t i = 0; i < 4; ++i) {
            const MatchEntry& entry = entries[first + i];
            if (entry.used && entry.context == history && entry.at < at &&
                at - entry.at <= MatchWindow) {
                donor = entry.at; active = true; ++eligible_bytes; return;
            }
        }
    }
    uint32_t predict(unsigned bit_position, uint32_t fallback,
                     const std::vector<uint8_t>& prior) const {
        if (!active || divergent) return fallback;
        bool expected = (prior[donor] >> (7 - bit_position)) & 1;
        const Counts& c = confidence[tier()][bit_position];
        uint32_t p_hit = ((uint32_t(c.one) + 1) * Q) /
                         (uint32_t(c.zero) + c.one + 2);
        uint32_t other = Q - p_hit;
        uint32_t p1 = expected ? p_hit + (other * fallback) / Q
                               : (other * fallback) / Q;
        return bounded_probability(p1);
    }
    void accept_bit(unsigned bit_position, bool bit,
                    const std::vector<uint8_t>& prior) {
        if (!active || divergent) return;
        bool expected = (prior[donor] >> (7 - bit_position)) & 1;
        add_count(confidence[tier()][bit_position], expected == bit);
        if (expected != bit) divergent = true;
    }
    void end(uint64_t history_before, uint32_t at) {
        if (active && !divergent) { ++donor; ++run; ++matched_bytes; }
        else { active = false; run = 0; }
        size_t first = bucket(history_before), target = first;
        for (size_t i = 0; i < 4; ++i) {
            MatchEntry& entry = entries[first + i];
            if (entry.used && entry.context == history_before) { target = first + i; break; }
            if (!entry.used) { target = first + i; break; }
            if (entry.age < entries[target].age) target = first + i;
        }
        if (entries[target].used && entries[target].context != history_before) ++replacements;
        entries[target] = MatchEntry{history_before, at, ++clock, true};
    }
};

struct MixerRow {
    std::array<int16_t, Experts + 1> weights{};
    std::array<int64_t, Experts + 1> residual{};
};

struct ScalarTracker {
    uint8_t pending = 0;
    uint32_t codepoint = 0, minimum = 0;
    bool feed(uint8_t byte) {
        if (pending && byte >= 0x80 && byte <= 0xbf) {
            codepoint = (codepoint << 6) | (byte & 63);
            if (--pending) return false;
            if (codepoint < minimum || codepoint > 0x10ffff ||
                (codepoint >= 0xd800 && codepoint <= 0xdfff)) return false;
            return (codepoint >= 0x3040 && codepoint <= 0x30ff) ||
                   (codepoint >= 0x3400 && codepoint <= 0x9fff);
        }
        pending = 0;
        if (byte >= 0xc2 && byte <= 0xdf) { codepoint = byte & 31; pending = 1; minimum = 0x80; }
        else if (byte >= 0xe0 && byte <= 0xef) { codepoint = byte & 15; pending = 2; minimum = 0x800; }
        else if (byte >= 0xf0 && byte <= 0xf4) { codepoint = byte & 7; pending = 3; minimum = 0x10000; }
        return false;
    }
};
struct TokenState {
    WordRun current{}, previous{}, second_previous{};
    void finish() {
        if (current.len) { second_previous = previous; previous = current; current.clear(); }
    }
    void accept(uint8_t byte, bool scalar_boundary) {
        if (byte_boundary(byte)) { finish(); return; }
        if (current.len == 16) finish();
        current.push(byte);
        if (scalar_boundary) finish();
    }
};

struct PackedKey {
    std::array<uint64_t, 6> value{};
    std::array<uint16_t, 3> lengths{};
    uint8_t script = 0, kind = 0;
    uint64_t hash = 0;
    bool operator==(const PackedKey& other) const {
        return value == other.value && lengths == other.lengths &&
               script == other.script && kind == other.kind;
    }
    void seal() {
        uint64_t h = scramble(uint64_t(kind) | (uint64_t(script) << 8));
        for (uint64_t part : value) h = scramble(h ^ part);
        for (uint16_t part : lengths) h = scramble(h ^ part);
        hash = h;
    }
};
PackedKey byte_key(uint64_t history, unsigned order) {
    PackedKey key;
    key.value[0] = history & (order == 8 ? UINT64_MAX : ((uint64_t(1) << (8 * order)) - 1));
    key.kind = uint8_t(order);
    key.seal();
    return key;
}
PackedKey word_key(const TokenState& tokens, bool two, uint8_t script, bool scalar) {
    PackedKey key;
    key.value[0] = tokens.previous.lo;
    key.value[1] = tokens.previous.hi;
    key.value[2] = tokens.current.lo;
    key.value[3] = tokens.current.hi;
    key.lengths[0] = tokens.previous.len;
    key.lengths[1] = tokens.current.len;
    if (two) {
        key.value[4] = tokens.second_previous.lo;
        key.value[5] = tokens.second_previous.hi;
        key.lengths[2] = tokens.second_previous.len;
    }
    key.script = script;
    key.kind = uint8_t((two ? 20 : 10) + (scalar ? 1 : 0));
    key.seal();
    return key;
}

struct PrefixState {
    uint16_t prefix = 0, stamp = 0;  // prefix 0 means empty
    uint8_t zero = 0, one = 0;
};
struct PackedRow {
    PackedKey key{};
    std::array<PrefixState, 16> state{};
    uint32_t age = 0;
    uint16_t tick = 0;
    bool used = false;
};
struct PackedTable {
    std::vector<PackedRow> rows;
    uint32_t clock = 0, occupied = 0;
    uint64_t row_replacements = 0, prefix_replacements = 0;
    explicit PackedTable(unsigned bucket_bits) : rows((size_t(1) << bucket_bits) * 4) {}
    size_t bucket(const PackedKey& key) const { return size_t(key.hash & (rows.size() / 4 - 1)) * 4; }
    const PackedRow* find(const PackedKey& key) const {
        size_t first = bucket(key);
        for (size_t i = 0; i < 4; ++i) {
            const PackedRow& row = rows[first + i];
            if (row.used && row.key == key) return &row;
        }
        return nullptr;
    }
    uint32_t predict(const PackedKey& key, uint16_t prefix, uint32_t fallback) const {
        const PackedRow* row = find(key);
        if (!row) return fallback;
        for (const PrefixState& state : row->state) {
            if (state.prefix != prefix) continue;
            uint32_t total = uint32_t(state.zero) + state.one;
            return bounded_probability((uint32_t(state.one) * Q + Backoff * fallback) /
                                       (total + Backoff));
        }
        return fallback;
    }
    void update(const PackedKey& key, uint16_t prefix, bool bit) {
        size_t first = bucket(key), target = first;
        for (size_t i = 0; i < 4; ++i) {
            PackedRow& row = rows[first + i];
            if (row.used && row.key == key) { target = first + i; break; }
            if (!row.used) { target = first + i; break; }
            if (row.age < rows[target].age) target = first + i;
        }
        PackedRow& row = rows[target];
        if (!row.used) { ++occupied; row = PackedRow{}; row.key = key; row.used = true; }
        else if (!(row.key == key)) { ++row_replacements; row = PackedRow{}; row.key = key; row.used = true; }
        row.age = ++clock;
        if (++row.tick == 0) {
            for (PrefixState& state : row.state) state.stamp = 0;
            row.tick = 1;
        }
        size_t chosen = 0;
        for (size_t i = 0; i < row.state.size(); ++i) {
            PrefixState& state = row.state[i];
            if (state.prefix == prefix) { chosen = i; break; }
            if (state.prefix == 0) { chosen = i; break; }
            if (state.stamp < row.state[chosen].stamp) chosen = i;
        }
        PrefixState& state = row.state[chosen];
        if (state.prefix != prefix) {
            if (state.prefix) ++prefix_replacements;
            state = PrefixState{prefix, 0, 0, 0};
        }
        state.stamp = row.tick;
        if (bit) ++state.one; else ++state.zero;
        if (uint32_t(state.zero) + state.one >= 250) {
            state.zero = uint8_t((uint32_t(state.zero) + 1) >> 1);
            state.one = uint8_t((uint32_t(state.one) + 1) >> 1);
        }
    }
};

struct Variant {
    std::string name;
    size_t active = 11;
    std::vector<MixerRow> mixer = std::vector<MixerRow>(MixContexts);
    std::array<double, 4> quarters{};
    explicit Variant(std::string label, size_t features) : name(std::move(label)), active(features) {
        for (MixerRow& row : mixer)
            for (size_t i = 0; i < active; ++i) row.weights[i] = int16_t(256 / active);
    }
    void accept(const Tables& table, const std::array<uint32_t, Experts>& p,
                uint16_t context, bool bit, unsigned quarter) {
        MixerRow& row = mixer[context];
        std::array<int16_t, Experts + 1> x{};
        int64_t dot = 0;
        for (size_t i = 0; i < active; ++i) {
            x[i] = table.stretch[p[i]];
            dot += int64_t(row.weights[i]) * x[i];
        }
        x[Experts] = 256;
        dot += int64_t(row.weights[Experts]) * x[Experts];
        uint32_t mixed = table.squash(int32_t(floor_shift(dot, 8)));
        quarters[quarter] -= std::log2(double(bit ? mixed : Q - mixed) / Q);
        int32_t error = (bit ? int32_t(Q) : 0) - int32_t(mixed);
        for (size_t i = 0; i <= active; ++i) {
            size_t slot = i == active ? Experts : i;
            row.residual[slot] += int64_t(error) * x[slot];
            int64_t delta = row.residual[slot] / (int64_t(1) << 24); // C++20 truncates toward zero
            row.residual[slot] -= delta * (int64_t(1) << 24);
            int64_t next = int64_t(row.weights[slot]) + delta;
            if (next < -512 || next > 512) row.residual[slot] = 0;
            row.weights[slot] = int16_t(std::clamp<int64_t>(next, -512, 512));
        }
    }
};

struct Model {
    Tables tables;
    std::array<Counts, 256> base{};
    std::array<Counts, 8 * 4 * 256> script_rows{};
    std::array<std::unique_ptr<PackedTable>, 8> byte_tables;
    std::array<std::unique_ptr<PackedTable>, 4> joint_tables;
    MatchState match;
    ScriptState script;
    ScalarTracker scalar;
    TokenState words{}, scalar_words{};
    std::vector<Variant> variants;
    std::array<std::array<double, 4>, 15> expert_quarters{};
    uint64_t history = 0, source_bits = 0;
    Model() {
        for (unsigned o = 1; o <= 8; ++o)
            byte_tables[o-1] = std::make_unique<PackedTable>(o == 1 ? 8 : o == 2 ? 14 : 16);
        for (auto& table : joint_tables) table = std::make_unique<PackedTable>(15);
        variants.reserve(4);
        variants.emplace_back("packed_orders_only", 11);
        variants.emplace_back("joint_previous1", 12);
        variants.emplace_back("joint_previous2", 13);
        variants.emplace_back("joint_previous2_scalar_segments", 13);
    }
    void accept_byte(uint8_t value, uint32_t at, const std::vector<uint8_t>& raw) {
        match.begin(history, at);
        uint64_t before = history;
        std::array<PackedKey, 8> byte_keys;
        for (unsigned o = 1; o <= 8; ++o) byte_keys[o-1] = byte_key(history, o);
        std::array<PackedKey, 4> joint_keys{
            word_key(words, false, script.script, false),
            word_key(words, true, script.script, false),
            word_key(scalar_words, false, script.script, true),
            word_key(scalar_words, true, script.script, true)};
        uint16_t prefix = 1;
        unsigned quarter = raw.empty() ? 0 : std::min<unsigned>(3, unsigned((uint64_t(at) * 4) / raw.size()));
        for (unsigned bpos = 0; bpos < 8; ++bpos) {
            bool bit = (value >> (7 - bpos)) & 1;
            const Counts& c = base[prefix];
            std::array<uint32_t, Experts> p{};
            p[0] = bounded_probability(((uint32_t(c.one) + 1) * Q) /
                                       (uint32_t(c.zero) + c.one + 2));
            for (unsigned o = 1; o <= 8; ++o)
                p[o] = byte_tables[o-1]->predict(byte_keys[o-1], prefix, p[o-1]);
            uint32_t script_index = (uint32_t(script.script) * 4 + script.boundary) * 256 + prefix;
            p[9] = predict_counts(&script_rows[script_index], p[2]);
            p[10] = match.predict(bpos, p[8], raw);
            p[11] = joint_tables[0]->predict(joint_keys[0], prefix, p[8]);
            p[12] = joint_tables[1]->predict(joint_keys[1], prefix, p[11]);
            uint32_t scalar_joint1 = joint_tables[2]->predict(joint_keys[2], prefix, p[8]);
            uint32_t scalar_joint2 = joint_tables[3]->predict(joint_keys[3], prefix, scalar_joint1);
            std::array<uint32_t, Experts> scalar_p = p;
            scalar_p[11] = scalar_joint1; scalar_p[12] = scalar_joint2;
            uint16_t context = uint16_t(bpos | (script.script << 3) |
                                       (script.boundary << 6) | (match.tier() << 8));
            for (size_t i = 0; i < variants.size(); ++i)
                variants[i].accept(tables, i == 3 ? scalar_p : p, context, bit, quarter);
            for (size_t i = 0; i < Experts; ++i)
                expert_quarters[i][quarter] -= std::log2(double(bit ? p[i] : Q - p[i]) / Q);
            expert_quarters[13][quarter] -= std::log2(double(bit ? scalar_joint1 : Q - scalar_joint1) / Q);
            expert_quarters[14][quarter] -= std::log2(double(bit ? scalar_joint2 : Q - scalar_joint2) / Q);
            add_count(base[prefix], bit);
            add_count(script_rows[script_index], bit);
            for (unsigned o = 1; o <= 8; ++o) byte_tables[o-1]->update(byte_keys[o-1], prefix, bit);
            for (size_t i = 0; i < 4; ++i) joint_tables[i]->update(joint_keys[i], prefix, bit);
            match.accept_bit(bpos, bit, raw);
            prefix = uint16_t((prefix << 1) | bit);
            ++source_bits;
        }
        match.end(before, at);
        history = (history << 8) | value;
        script.feed(value);
        bool scalar_boundary = scalar.feed(value);
        words.accept(value, false);
        scalar_words.accept(value, scalar_boundary);
    }
    uint64_t fixed_bytes(const std::vector<uint8_t>& raw) const {
        uint64_t bytes = raw.capacity() + sizeof(*this) + variants.capacity() * sizeof(Variant);
        for (const auto& table : byte_tables) bytes += table->rows.capacity() * sizeof(PackedRow);
        for (const auto& table : joint_tables) bytes += table->rows.capacity() * sizeof(PackedRow);
        bytes += match.entries.capacity() * sizeof(MatchEntry);
        for (const Variant& v : variants) bytes += v.mixer.capacity() * sizeof(MixerRow);
        return bytes;
    }
};

} // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: ccw_score SOURCE");
        std::ifstream in(argv[1], std::ios::binary);
        if (!in) throw std::runtime_error("cannot open source");
        std::vector<uint8_t> raw((std::istreambuf_iterator<char>(in)), {});
        if (raw.size() > MaxSource) throw std::runtime_error("source exceeds 16 MiB scorer cap");
        Model model;
        if (model.fixed_bytes(raw) > (uint64_t(512) << 20))
            throw std::runtime_error("state plus source exceeds 512 MiB cap");
        for (size_t i = 0; i < raw.size(); ++i) model.accept_byte(raw[i], uint32_t(i), raw);
        const char* expert_names[] = {"partial_byte", "byte1", "byte2", "byte3", "byte4",
                                      "byte5", "byte6", "byte7", "byte8", "script_boundary",
                                      "match", "joint_previous1", "joint_previous2",
                                      "scalar_joint_previous1", "scalar_joint_previous2"};
        std::cout << std::setprecision(12);
        std::cout << "{\"status\":\"development_only_q15_ideal_bits_not_frame_bytes\",";
        std::cout << "\"source_bytes\":" << raw.size() << ",\"source_bits\":" << model.source_bits;
        std::cout << ",\"fixed_state_plus_source_bytes\":" << model.fixed_bytes(raw);
        std::cout << ",\"sizeof_packed_row\":" << sizeof(PackedRow) << ",\"experts\":{";
        for (size_t i = 0; i < 15; ++i) {
            if (i) std::cout << ',';
            std::cout << '"' << expert_names[i] << "\":{\"quarter_bits\":[";
            double total = 0;
            for (size_t q = 0; q < 4; ++q) {
                if (q) std::cout << ',';
                std::cout << model.expert_quarters[i][q]; total += model.expert_quarters[i][q];
            }
            std::cout << "],\"total_bits\":" << total << '}';
        }
        std::cout << "},\"variants\":{";
        for (size_t i = 0; i < model.variants.size(); ++i) {
            if (i) std::cout << ',';
            const Variant& v = model.variants[i];
            std::cout << '"' << v.name << "\":{\"quarter_bits\":[";
            double total = 0;
            for (size_t q = 0; q < 4; ++q) {
                if (q) std::cout << ',';
                std::cout << v.quarters[q]; total += v.quarters[q];
            }
            std::cout << "],\"total_bits\":" << total << '}';
        }
        std::cout << "},\"tables\":{";
        for (size_t i = 0; i < 12; ++i) {
            if (i) std::cout << ',';
            const PackedTable& table = i < 8 ? *model.byte_tables[i] : *model.joint_tables[i-8];
            std::cout << '"' << (i < 8 ? "byte" : "joint") << (i < 8 ? i+1 : i-7)
                      << "\":{\"capacity\":" << table.rows.size()
                      << ",\"occupied\":" << table.occupied
                      << ",\"row_replacements\":" << table.row_replacements
                      << ",\"prefix_replacements\":" << table.prefix_replacements << '}';
        }
        std::cout << "},\"match_eligible_bytes\":" << model.match.eligible_bytes
                  << ",\"match_continuation_bytes\":" << model.match.matched_bytes
                  << ",\"match_replacements\":" << model.match.replacements << "}\n";
    } catch (const std::exception& error) { std::cerr << error.what() << '\n'; return 1; }
}
