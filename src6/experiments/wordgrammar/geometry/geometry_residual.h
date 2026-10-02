#ifndef WORDGRAMMAR_GEOMETRY_RESIDUAL_H
#define WORDGRAMMAR_GEOMETRY_RESIDUAL_H

// Integer-only inverse of context_tree.py's page residual. The model is a
// preorder tree of 3-byte nodes; all bytes and page boundaries are literal.
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

namespace geometry_residual {

static constexpr size_t page_bytes = 65536;
static constexpr uint32_t scale = 4096;
static constexpr uint32_t low = 1u << 23;

inline uint16_t little16(std::string_view bytes, size_t at) {
    return static_cast<uint16_t>(static_cast<unsigned char>(bytes[at])) |
           static_cast<uint16_t>(static_cast<unsigned char>(bytes[at + 1])) << 8;
}

inline uint32_t little32(std::string_view bytes) {
    return static_cast<uint32_t>(static_cast<unsigned char>(bytes[0])) |
           static_cast<uint32_t>(static_cast<unsigned char>(bytes[1])) << 8 |
           static_cast<uint32_t>(static_cast<unsigned char>(bytes[2])) << 16 |
           static_cast<uint32_t>(static_cast<unsigned char>(bytes[3])) << 24;
}

class Model {
    struct Node {
        uint8_t kind;
        uint16_t value;
        uint16_t left = 0, right = 0;
    };
    std::vector<Node> nodes_;
    size_t leaves_ = 0;

    uint16_t parse(std::string_view wire, size_t& at, unsigned depth) {
        if (depth > 16 || at > wire.size() || wire.size() - at < 3 || nodes_.size() >= 511)
            throw std::runtime_error("geometry tree depth, node count, or truncation");
        const uint8_t kind = static_cast<uint8_t>(wire[at]);
        const uint16_t value = little16(wire, at + 1);
        at += 3;
        const uint16_t index = static_cast<uint16_t>(nodes_.size());
        nodes_.push_back({kind, value});
        if (kind == 0) {
            if (value > scale || ++leaves_ > 256)
                throw std::runtime_error("geometry tree leaf frequency or count");
            return index;
        }
        const uint16_t maximum = kind == 1 ? 1 : ((kind == 2 || kind == 3) ? 4096 : 255);
        if (kind > 5 || value > maximum)
            throw std::runtime_error("geometry tree feature or threshold");
        const uint16_t left = parse(wire, at, depth + 1);
        const uint16_t right = parse(wire, at, depth + 1);
        nodes_[index].left = left;
        nodes_[index].right = right;
        return index;
    }

public:
    explicit Model(std::string_view wire) {
        if (wire.empty() || wire.size() > 1533)
            throw std::runtime_error("geometry tree byte bound");
        nodes_.reserve(511);
        size_t at = 0;
        parse(wire, at, 0);
        if (at != wire.size()) throw std::runtime_error("geometry tree trailing bytes");
    }

    uint16_t zero_frequency(const std::array<uint16_t, 5>& features) const {
        uint16_t at = 0;
        while (nodes_[at].kind != 0) {
            const Node& node = nodes_[at];
            at = features[node.kind - 1] <= node.value ? node.left : node.right;
        }
        return nodes_[at].value;
    }
};

inline bool whitespace(unsigned char c) { return c == ' ' || c == '\n'; }

inline std::string realize(std::string_view normalized, std::string_view flags,
                           const Model& model, size_t count, unsigned width) {
    if (normalized.size() > page_bytes || flags.size() < 4 ||
        count > normalized.size() || flags.size() - 4 > 2 * count ||
        width == 0 || width > 4096)
        throw std::runtime_error("geometry page bound");
    uint64_t state = little32(flags);
    if (state < low || state >= static_cast<uint64_t>(low) * 256)
        throw std::runtime_error("geometry initial state");
    size_t position = 4, seen = 0, column = 0;
    unsigned previous_last = 0;
    std::string output(normalized);
    for (size_t at = 0; at < normalized.size();) {
        const bool space_run = whitespace(static_cast<unsigned char>(normalized[at]));
        size_t end = at + 1;
        while (end < normalized.size() &&
               whitespace(static_cast<unsigned char>(normalized[end])) == space_run) ++end;
        if (space_run && end == at + 1 && end < normalized.size()) {
            if (normalized[at] != ' ' || seen >= count)
                throw std::runtime_error("geometry separator slot");
            size_t next_end = end + 1;
            while (next_end < normalized.size() &&
                   !whitespace(static_cast<unsigned char>(normalized[next_end]))) ++next_end;
            const size_t next_length = next_end - end;
            const std::array<uint16_t, 5> features = {
                static_cast<uint16_t>(column + 1 + next_length > width),
                static_cast<uint16_t>(std::min<size_t>(column, 4096)),
                static_cast<uint16_t>(std::min<size_t>(next_length, 4096)),
                static_cast<uint16_t>(previous_last),
                static_cast<uint16_t>(static_cast<unsigned char>(normalized[end]))
            };
            const uint16_t zero = model.zero_frequency(features);
            const uint32_t residue = static_cast<uint32_t>(state & (scale - 1));
            const unsigned symbol = residue >= zero;
            const uint32_t start = symbol ? zero : 0;
            const uint32_t frequency = symbol ? scale - zero : zero;
            if (frequency == 0) throw std::runtime_error("geometry zero frequency");
            state = static_cast<uint64_t>(frequency) * (state >> 12) + residue - start;
            while (state < low) {
                if (position == flags.size()) throw std::runtime_error("geometry flag truncation");
                state = state << 8 | static_cast<unsigned char>(flags[position++]);
            }
            output[at] = (features[0] ^ symbol) ? '\n' : ' ';
            ++seen;
        }
        for (size_t i = at; i < end; ++i)
            column = output[i] == '\n' ? 0 : column + 1;
        previous_last = static_cast<unsigned char>(normalized[end - 1]);
        at = end;
    }
    if (seen != count || position != flags.size() || state != low)
        throw std::runtime_error("geometry noncanonical tail");
    return output;
}

} // namespace geometry_residual

#endif
