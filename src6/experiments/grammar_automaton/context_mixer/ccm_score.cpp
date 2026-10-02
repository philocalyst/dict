// CCM1: fixed-point, context-conditioned bit model. Source-only DEV scorer.
// The predictor uses integer state; floating log2 is confined to reporting.
#include "squash_table.h"
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
constexpr size_t Experts = 9;
constexpr size_t MixContexts = 1024;
constexpr size_t APMKnots = 33;
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
struct TaggedRow { Key key{}; Counts count{}; uint32_t age = 0; bool used = false; };
struct TaggedTable {
    std::vector<TaggedRow> rows;
    uint32_t clock = 0;
    uint32_t occupied = 0;
    uint64_t replacements = 0;
    explicit TaggedTable(unsigned bucket_bits) : rows((size_t(1) << bucket_bits) * 4) {}
    size_t bucket(const Key& key) const {
        uint64_t h = scramble(key.a ^ scramble(key.b + uint64_t(key.aux) * 0x9e3779b97f4a7c15ULL) ^
                              uint64_t(key.prefix) * 0xd6e8feb86659fd93ULL);
        return size_t(h & (rows.size() / 4 - 1)) * 4;
    }
    const Counts* lookup(const Key& key) const {
        size_t first = bucket(key);
        for (size_t i = 0; i < 4; ++i) {
            const TaggedRow& row = rows[first + i];
            if (row.used && row.key == key) return &row.count;
        }
        return nullptr;
    }
    uint32_t predict(const Key& key, uint32_t fallback) const {
        return predict_counts(lookup(key), fallback);
    }
    void update(const Key& key, bool bit) {
        size_t first = bucket(key), target = first;
        for (size_t i = 0; i < 4; ++i) {
            TaggedRow& row = rows[first + i];
            if (row.used && row.key == key) { target = first + i; break; }
            if (!row.used) { target = first + i; break; }
            if (row.age < rows[target].age) target = first + i;
        }
        TaggedRow& row = rows[target];
        if (!row.used) { ++occupied; row = TaggedRow{key, Counts{}, 0, true}; }
        else if (!(row.key == key)) { ++replacements; row = TaggedRow{key, Counts{}, 0, true}; }
        row.age = ++clock;
        add_count(row.count, bit);
    }
};

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
    MixerRow() {
        for (size_t i = 0; i < Experts; ++i) weights[i] = int16_t(256 / Experts);
    }
};
struct APMRow { std::array<uint16_t, APMKnots> knot{}; };
struct Variant {
    std::string name;
    bool conditional = true, apm = true, words = true, match = true;
    std::vector<MixerRow> mixer;
    std::vector<APMRow> calibration;
    std::array<double, 4> section_bits{};
    uint64_t emitted_bits = 0;
    Variant(std::string label, bool cond, bool use_apm, bool use_words, bool use_match)
        : name(std::move(label)), conditional(cond), apm(use_apm),
          words(use_words), match(use_match), mixer(cond ? MixContexts : 1),
          calibration(use_apm ? MixContexts : 0) {
        for (APMRow& row : calibration)
            for (size_t i = 0; i < APMKnots; ++i)
                row.knot[i] = kSquash[i * 128];
    }
    void accept(const Tables& table, const std::array<uint32_t, Experts>& original,
                uint16_t context, bool bit, unsigned section) {
        auto p = original;
        if (!words) { p[5] = p[2]; p[6] = p[2]; }
        if (!match) p[8] = p[4];
        MixerRow& row = mixer[conditional ? context : 0];
        std::array<int16_t, Experts + 1> x{};
        int64_t dot = 0;
        for (size_t i = 0; i < Experts; ++i) {
            x[i] = table.stretch[p[i]];
            dot += int64_t(row.weights[i]) * x[i];
        }
        x[Experts] = 256;  // bias feature: one log-odds unit
        dot += int64_t(row.weights[Experts]) * x[Experts];
        uint32_t mixed = table.squash(int32_t(floor_shift(dot, 8)));
        uint32_t output = mixed;
        uint32_t index = 0, fraction = 0;
        if (apm) {
            int32_t shifted = int32_t(table.stretch[mixed]) + 2048;
            index = std::min<uint32_t>(uint32_t(shifted >> 7), 31);
            fraction = uint32_t(shifted) & 127;
            APMRow& knots = calibration[context];
            output = bounded_probability((uint32_t(knots.knot[index]) * (128 - fraction) +
                                          uint32_t(knots.knot[index + 1]) * fraction + 64) >> 7);
        }
        section_bits[section] -= std::log2(double(bit ? output : Q - output) / Q);
        ++emitted_bits;
        int32_t error = (bit ? int32_t(Q) : 0) - int32_t(mixed);
        for (size_t i = 0; i < row.weights.size(); ++i) {
            row.residual[i] += int64_t(error) * x[i];
            // Signed division truncates toward zero in C++20; residual keeps
            // all discarded low bits so small gradients are not rounded away.
            int64_t delta = row.residual[i] / (int64_t(1) << 24);
            row.residual[i] -= delta * (int64_t(1) << 24);
            int64_t next = int64_t(row.weights[i]) + delta;
            if (next < -512 || next > 512) row.residual[i] = 0;
            row.weights[i] = int16_t(std::clamp<int64_t>(next, -512, 512));
        }
        if (apm) {
            APMRow& knots = calibration[context];
            int64_t target = bit ? Q : 0;
            for (uint32_t i : {index, index + 1}) {
                int64_t delta = floor_shift(target - knots.knot[i], 7);
                knots.knot[i] = uint16_t(std::clamp<int64_t>(int64_t(knots.knot[i]) + delta,
                                                            1, Q - 1));
            }
        }
    }
};

struct Model {
    Tables tables;
    std::array<Counts, 256> base{};
    std::array<Counts, 8 * 4 * 256> script_rows{};
    TaggedTable byte1{14}, byte2{15}, byte4{16}, byte8{16};
    TaggedTable prior_word{16}, current_word{16};
    MatchState match;
    WordRun current{}, previous{};
    ScriptState script;
    std::vector<Variant> variants;
    std::array<std::array<double, 4>, Experts> expert_sections{};
    uint64_t history = 0;
    uint64_t bit_count = 0;
    Model() {
        variants.reserve(5);
        variants.emplace_back("global_logit", false, false, true, true);
        variants.emplace_back("conditional_logit", true, false, true, true);
        variants.emplace_back("conditional_apm", true, true, true, true);
        variants.emplace_back("conditional_apm_no_words", true, true, false, true);
        variants.emplace_back("conditional_apm_no_match", true, true, true, false);
    }
    void accept_byte(uint8_t value, uint32_t at, const std::vector<uint8_t>& raw) {
        match.begin(history, at);
        uint64_t before = history;
        uint16_t prefix = 1;
        unsigned section = raw.empty() ? 0 : std::min<unsigned>(3, unsigned((uint64_t(at) * 4) / raw.size()));
        for (unsigned bpos = 0; bpos < 8; ++bpos) {
            bool bit = (value >> (7 - bpos)) & 1;
            const Counts& c = base[prefix];
            uint32_t p0 = bounded_probability(((uint32_t(c.one) + 1) * Q) /
                                               (uint32_t(c.zero) + c.one + 2));
            Key k1{history & 0xff, 0, prefix, 0};
            Key k2{history & 0xffff, 0, prefix, 0};
            Key k4{history & 0xffffffffULL, 0, prefix, 0};
            Key k8{history, 0, prefix, 0};
            Key kw{previous.lo, previous.hi, prefix, previous.len};
            Key kc{current.lo, current.hi, prefix, current.len};
            uint32_t p1 = byte1.predict(k1, p0);
            uint32_t p2 = byte2.predict(k2, p1);
            uint32_t p4 = byte4.predict(k4, p2);
            uint32_t p8 = byte8.predict(k8, p4);
            uint32_t ppw = prior_word.predict(kw, p2);
            uint32_t pcw = current_word.predict(kc, p2);
            uint32_t script_index = (uint32_t(script.script) * 4 + script.boundary) * 256 + prefix;
            uint32_t ps = predict_counts(&script_rows[script_index], p2);
            uint32_t pm = match.predict(bpos, p8, raw);
            std::array<uint32_t, Experts> p{p0, p1, p2, p4, p8, ppw, pcw, ps, pm};
            uint16_t context = uint16_t(bpos | (script.script << 3) |
                                       (script.boundary << 6) | (match.tier() << 8));
            for (Variant& variant : variants)
                variant.accept(tables, p, variant.match ? context : uint16_t(context & 255), bit, section);
            for (size_t i = 0; i < Experts; ++i)
                expert_sections[i][section] -= std::log2(double(bit ? p[i] : Q - p[i]) / Q);
            add_count(base[prefix], bit);
            byte1.update(k1, bit); byte2.update(k2, bit);
            byte4.update(k4, bit); byte8.update(k8, bit);
            prior_word.update(kw, bit); current_word.update(kc, bit);
            add_count(script_rows[script_index], bit);
            match.accept_bit(bpos, bit, raw);
            prefix = uint16_t((prefix << 1) | bit);
            ++bit_count;
        }
        match.end(before, at);
        history = (history << 8) | value;
        if (byte_boundary(value)) {
            if (current.len) previous = current;
            current.clear();
        } else {
            if (current.len == 16) { previous = current; current.clear(); }
            current.push(value);
        }
        script.feed(value);
    }
    uint64_t fixed_bytes(const std::vector<uint8_t>& raw) const {
        uint64_t bytes = raw.capacity() + sizeof(*this) + variants.capacity() * sizeof(Variant);
        for (const TaggedTable* t : {&byte1, &byte2, &byte4, &byte8, &prior_word, &current_word})
            bytes += t->rows.capacity() * sizeof(TaggedRow);
        bytes += match.entries.capacity() * sizeof(MatchEntry);
        for (const Variant& v : variants) {
            bytes += v.mixer.capacity() * sizeof(MixerRow);
            bytes += v.calibration.capacity() * sizeof(APMRow);
        }
        return bytes;
    }
};

}  // namespace

int main(int argc, char** argv) {
    try {
        if (argc != 2) throw std::runtime_error("usage: ccm_score SOURCE");
        std::ifstream in(argv[1], std::ios::binary);
        if (!in) throw std::runtime_error("cannot open source");
        std::vector<uint8_t> raw((std::istreambuf_iterator<char>(in)), {});
        if (raw.size() > MaxSource) throw std::runtime_error("source exceeds 16 MiB scorer cap");
        Model model;
        for (size_t i = 0; i < raw.size(); ++i) model.accept_byte(raw[i], uint32_t(i), raw);
        const char* names[] = {"partial_byte", "prior_byte1", "prior_byte2", "prior_byte4",
                               "prior_byte8", "previous_word", "current_word_prefix",
                               "script_boundary", "match_continuation"};
        std::cout << std::setprecision(12);
        std::cout << "{\"status\":\"development_only_q15_ideal_bits_not_frame_bytes\",";
        std::cout << "\"source_bytes\":" << raw.size() << ",\"source_bits\":" << model.bit_count;
        std::cout << ",\"fixed_state_plus_source_bytes\":" << model.fixed_bytes(raw);
        std::cout << ",\"experts\":{";
        for (size_t i = 0; i < Experts; ++i) {
            if (i) std::cout << ',';
            std::cout << '"' << names[i] << "\":{\"quarter_bits\":[";
            double total = 0;
            for (size_t j = 0; j < 4; ++j) {
                if (j) std::cout << ',';
                std::cout << model.expert_sections[i][j];
                total += model.expert_sections[i][j];
            }
            std::cout << "],\"total_bits\":" << total << '}';
        }
        std::cout << "},\"variants\":{";
        for (size_t i = 0; i < model.variants.size(); ++i) {
            if (i) std::cout << ',';
            const Variant& v = model.variants[i];
            std::cout << '"' << v.name << "\":{\"quarter_bits\":[";
            double total = 0;
            for (size_t j = 0; j < 4; ++j) {
                if (j) std::cout << ',';
                std::cout << v.section_bits[j];
                total += v.section_bits[j];
            }
            std::cout << "],\"total_bits\":" << total << '}';
        }
        std::cout << "},\"tagged_tables\":{";
        const TaggedTable* tables[] = {&model.byte1, &model.byte2, &model.byte4,
                                       &model.byte8, &model.prior_word, &model.current_word};
        const char* table_names[] = {"byte1", "byte2", "byte4", "byte8", "previous_word", "current_word"};
        for (size_t i = 0; i < 6; ++i) {
            if (i) std::cout << ',';
            std::cout << '"' << table_names[i] << "\":{\"capacity\":" << tables[i]->rows.size()
                      << ",\"occupied\":" << tables[i]->occupied
                      << ",\"replacements\":" << tables[i]->replacements << '}';
        }
        std::cout << "},\"match_eligible_bytes\":" << model.match.eligible_bytes
                  << ",\"match_continuation_bytes\":" << model.match.matched_bytes
                  << ",\"match_replacements\":" << model.match.replacements << "}\n";
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; return 1;
    }
}
