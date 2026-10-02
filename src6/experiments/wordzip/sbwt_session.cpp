// Reusable reader experiment. The frozen codec source is included unchanged.
// Preparation retains immutable flat spellings, entropy tables and a directory.
#define main wordzip_frozen_cli_main
#pragma GCC diagnostic push
// The included CLI is never called; renamed main loses C++'s implicit return.
#pragma GCC diagnostic ignored "-Wreturn-type"
#include "sbwt.cpp"
#pragma GCC diagnostic pop
#undef main

#include <fcntl.h>
#include <memory>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

namespace wordzip_session {

struct Mapping {
    const uint8_t *data = nullptr;
    size_t size = 0;

    explicit Mapping(const char *path) {
        int fd = ::open(path, O_RDONLY | O_CLOEXEC);
        need(fd >= 0, "open mapped frame");
        struct stat info{};
        if (::fstat(fd, &info) != 0 || info.st_size < 40 || uint64_t(info.st_size) > MAXFRAME) {
            ::close(fd);
            throw std::runtime_error("mapped frame resource limit");
        }
        size = size_t(info.st_size);
        void *mapped = ::mmap(nullptr, size, PROT_READ, MAP_PRIVATE, fd, 0);
        ::close(fd);
        need(mapped != MAP_FAILED, "map frame");
        data = static_cast<const uint8_t *>(mapped);
        // This requests a paging policy; it does not promise exact physical I/O.
        ::madvise(const_cast<uint8_t *>(data), size, MADV_RANDOM);
    }
    Mapping(const Mapping &) = delete;
    Mapping &operator=(const Mapping &) = delete;
    ~Mapping() {
        if (data)
            ::munmap(const_cast<uint8_t *>(data), size);
    }
    Bytes copy(size_t offset, size_t length) const {
        need(offset <= size && length <= size - offset, "mapped span bounds");
        return Bytes(data + offset, data + offset + length);
    }
};

struct Spelling {
    uint32_t offset;
    uint32_t length;
};

struct State {
    std::shared_ptr<const Mapping> mapping;
    uint64_t raw_bytes = 0;
    size_t metadata_bytes = 0;
    uint32_t block_bytes = 0;
    bool surface_bindings = false;
    Bytes spellings;
    std::vector<Spelling> symbols;
    std::vector<Rans> entropy;
    Rans parameter_entropy;
    std::vector<Record> directory;
};

static std::shared_ptr<const State> prepare(const char *path) {
    auto state = std::make_shared<State>();
    state->mapping = std::make_shared<Mapping>(path);
    auto &mapped = *state->mapping;
    auto header = mapped.copy(0, 40);
    need(std::memcmp(header.data(), "WSB2", 4) == 0, "mapped frame magic");
    Reader h{header, 4};
    auto version = h.r32(), block = h.r32(), count = h.r32();
    auto raw = h.r64();
    auto grammar_length = h.r32(), entropy_length = h.r32(), checksum = h.r32(), flags = h.r32();
    need(version == 2 && flags < 32 && (flags & 15) < 12 && count <= 1000000 &&
             grammar_length <= 9 * 1024 * 1024 && entropy_length <= 9 * 1024 * 1024 &&
             raw <= MAXRAW && block && block <= 4 * 1024 * 1024 &&
             count == (raw + block - 1) / block,
         "mapped frame header");
    uint64_t metadata_length = 40ull + grammar_length + entropy_length + 32ull * count;
    need(metadata_length <= mapped.size, "mapped metadata length");
    // Only metadata is copied during preparation. No payload is visited.
    auto metadata = mapped.copy(0, metadata_length);
    std::fill(metadata.begin() + 32, metadata.begin() + 36, 0);
    need(crc(metadata) == checksum, "mapped metadata checksum");
    Reader r{metadata, 40};
    auto dictionary = decompressmodel(r.take(grammar_length));
    unsigned dictionary_kind = (flags >> 2) & 3;
    auto grammar =
        dictionary_kind ? parseflat(dictionary, dictionary_kind == 2) : parsegrammar(dictionary);
    state->surface_bindings = flags & 16;
    if (state->surface_bindings)
        grammar.exp.push_back("");
    auto order = ordering(grammar, flags & 3);
    auto encoded_entropy = decompressmodel(r.take(entropy_length));
    if (state->surface_bindings) {
        Reader e{encoded_entropy};
        auto main_length = e.get();
        state->entropy = contextual_parse(e.take(main_length));
        state->parameter_entropy = parsemodel(e.take(encoded_entropy.size() - e.p));
        need(state->parameter_entropy.f.size() == 256, "mapped parameter alphabet");
    } else {
        state->entropy = contextual_parse(encoded_entropy);
    }
    for (auto &row : state->entropy)
        need(row.f.size() == grammar.exp.size() + 1, "mapped event alphabet");

    // Precompose symbol order with expansion addresses. Block decoding needs
    // neither string objects, grammar edges, sorting nor a permutation pass.
    std::vector<Spelling> original;
    original.reserve(grammar.exp.size());
    for (auto &spelling : grammar.exp) {
        original.push_back({uint32_t(state->spellings.size()), uint32_t(spelling.size())});
        state->spellings.insert(state->spellings.end(), spelling.begin(), spelling.end());
    }
    state->symbols.reserve(order.size());
    for (auto symbol : order)
        state->symbols.push_back(original[symbol]);

    uint64_t offset = 0, total = 0;
    state->directory.reserve(count);
    for (size_t i = 0; i < count; i++) {
        Record q{r.r64(), r.r32(), r.r32(), r.r32(), r.r32(), r.r32(), r.r32()};
        size_t expected = std::min<uint64_t>(block, raw - total);
        need(q.offset == offset && q.raw == expected && q.encoded &&
                 q.encoded <= mapped.size - metadata_length - offset && q.roots &&
                 q.roots <= q.raw && q.evs && q.evs <= q.roots * 2,
             "mapped directory bounds");
        if (q.primary == UINT32_MAX)
            need(q.encoded == q.raw, "mapped raw payload length");
        else
            need(q.primary < q.roots, "mapped primary index");
        offset += q.encoded;
        total += q.raw;
        state->directory.push_back(q);
    }
    need(r.p == metadata.size() && metadata_length + offset == mapped.size && total == raw,
         "mapped exact frame length");
    state->raw_bytes = raw;
    state->metadata_bytes = metadata_length;
    state->block_bytes = block;
    return state;
}

class PreparedFrame {
    std::shared_ptr<const State> state_;

    const State &state() const {
        need(bool(state_), "empty prepared reader");
        return *state_;
    }

  public:
    PreparedFrame() = default;
    explicit PreparedFrame(const char *path) : state_(prepare(path)) {}
    size_t block_count() const { return state().directory.size(); }
    uint64_t raw_bytes() const { return state().raw_bytes; }
    size_t metadata_bytes() const { return state().metadata_bytes; }
    size_t frame_bytes() const { return state().mapping->size; }
    Record record(size_t index) const {
        auto &s = state();
        need(index < s.directory.size(), "prepared block index");
        return s.directory[index];
    }
    // Charge container objects and all vector capacities. Allocator/control-block
    // overhead and mapped resident pages are separate OS-accounting quantities.
    size_t model_bytes(bool capacity = true) const {
        auto &s = state();
        auto entries = [capacity](const auto &vector) {
            return capacity ? vector.capacity() : vector.size();
        };
        size_t bytes = sizeof(*this) + sizeof(State) + sizeof(Mapping) + entries(s.spellings) +
                       entries(s.symbols) * sizeof(Spelling) +
                       entries(s.directory) * sizeof(Record) + entries(s.entropy) * sizeof(Rans);
        for (auto &row : s.entropy)
            bytes += entries(row.f) * sizeof(uint32_t) + entries(row.c) * sizeof(uint32_t) +
                     entries(row.lookup) * sizeof(uint16_t);
        if (s.surface_bindings)
            bytes += entries(s.parameter_entropy.f) * sizeof(uint32_t) +
                     entries(s.parameter_entropy.c) * sizeof(uint32_t) +
                     entries(s.parameter_entropy.lookup) * sizeof(uint16_t);
        return bytes;
    }

    // Returned bytes own their storage and remain valid after every reader copy
    // and the mapping are destroyed. All transient decode buffers are local.
    Bytes decode_block(size_t index) const {
        auto &s = state();
        auto q = record(index);
        auto encoded = s.mapping->copy(s.metadata_bytes + q.offset, q.encoded);
        Bytes output;
        if (q.primary == UINT32_MAX) {
            output = std::move(encoded);
        } else {
            Bytes parameters;
            if (s.surface_bindings) {
                Reader p{encoded};
                auto main_length = p.r32(), parameter_length = p.r32();
                // One COPY root emits two canonical varints. Length is at most
                // 4096 (two bytes); distance is at most the raw block length.
                // This bounds the decoded parameter BYTE alphabet before its
                // rANS decoder allocates, including four-byte 4 MiB distances.
                uint32_t distance_bytes = 1;
                for (uint32_t distance = q.raw; distance >= 128; distance >>= 7)
                    ++distance_bytes;
                need(uint64_t(parameter_length) <= uint64_t(q.roots) * (2 + distance_bytes),
                     "prepared parameter count");
                auto main = p.take(main_length);
                auto values =
                    rdecode(p.take(encoded.size() - p.p), parameter_length, s.parameter_entropy);
                parameters = Bytes(values.begin(), values.end());
                encoded = std::move(main);
            }
            auto events = contextual_decode(encoded, q.evs, s.entropy);
            auto last = unevents(events, q.roots, s.symbols.size());
            auto symbols = ibwt(last, q.primary, s.symbols.size());
            Reader params{parameters};
            output.reserve(q.raw);
            for (auto symbol : symbols) {
                need(symbol < s.symbols.size(), "prepared expansion symbol");
                auto spelling = s.symbols[symbol];
                if (!spelling.length) {
                    need(s.surface_bindings, "unexpected empty spelling");
                    auto length = params.get(), distance = params.get();
                    need(length >= 6 && length <= 4096 && distance && distance <= output.size() &&
                             length <= q.raw - output.size(),
                         "prepared surface bounds");
                    size_t start = output.size();
                    output.resize(start + length);
                    size_t done = std::min(length, distance);
                    std::memcpy(output.data() + start, output.data() + start - distance, done);
                    while (done < length) {
                        size_t amount = std::min<uint64_t>(done, length - done);
                        std::memcpy(output.data() + start + done, output.data() + start, amount);
                        done += amount;
                    }
                } else {
                    need(spelling.length <= q.raw - output.size(), "prepared output bound");
                    output.insert(output.end(), s.spellings.begin() + spelling.offset,
                                  s.spellings.begin() + spelling.offset + spelling.length);
                }
            }
            need(output.size() == q.raw && params.p == parameters.size(),
                 "prepared output or parameters length");
        }
        need(crc(output) == q.sum, "prepared block checksum");
        return output;
    }

    Bytes decode_all() const {
        Bytes output;
        output.reserve(raw_bytes());
        for (size_t index = 0; index < block_count(); index++) {
            auto block = decode_block(index);
            output.insert(output.end(), block.begin(), block.end());
        }
        need(output.size() == raw_bytes(), "prepared whole length");
        return output;
    }
};

static uint64_t elapsed(std::chrono::steady_clock::time_point begin) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() -
                                                                begin)
        .count();
}

} // namespace wordzip_session

int main(int argc, char **argv) {
    try {
        need(argc >= 4, "usage: sbwt-session decode|bench-reader|lifetime-check FRAME OUTPUT "
                        "[--index N] [--measure 0|1 --quiet-gate WORDZIP-READER-QUIET]");
        std::string operation = argv[1];
        int64_t index = -1;
        bool measure = false, quiet = false;
        for (int i = 4; i < argc; i += 2) {
            need(i + 1 < argc, "reader option value");
            std::string option = argv[i], value = argv[i + 1];
            if (option == "--index") {
                auto selected = std::stoull(value);
                need(selected <= 1000000, "reader index range");
                index = selected;
            } else if (option == "--measure") {
                need(value == "0" || value == "1", "reader measure flag");
                measure = value == "1";
            } else if (option == "--quiet-gate") {
                quiet = value == "WORDZIP-READER-QUIET";
            } else {
                throw std::runtime_error("reader unknown option");
            }
        }
        need(!measure || quiet, "reader timing requires quiet gate");
        auto open_begin = std::chrono::steady_clock::now();
        wordzip_session::PreparedFrame reader(argv[2]);
        uint64_t preparation_ns = measure ? wordzip_session::elapsed(open_begin) : 0;
        if (operation == "decode") {
            auto output = index < 0 ? reader.decode_all() : reader.decode_block(index);
            write(argv[3], output);
            std::cout << "{\"output_bytes\":" << output.size()
                      << ",\"blocks\":" << reader.block_count()
                      << ",\"prepared_model_bytes\":" << reader.model_bytes()
                      << ",\"metadata_bytes\":" << reader.metadata_bytes() << "}\n";
        } else if (operation == "lifetime-check") {
            need(reader.block_count(), "lifetime check needs a block");
            auto copy = reader;
            reader = {};
            auto moved = std::move(copy);
            auto output = moved.decode_block(index < 0 ? 0 : index);
            moved = {};
            write(argv[3], output);
            std::cout << "{\"lifetime_verified\":true,\"output_bytes\":" << output.size() << "}\n";
        } else if (operation == "bench-reader") {
            need(reader.block_count(), "reader benchmark needs a block");
            uint64_t decode_ns = 0, checksum = 1469598103934665603ull, decoded = 0;
            uint64_t requested = reader.metadata_bytes();
            std::vector<bool> visited(reader.block_count());
            for (size_t access = 0; access < 256; access++) {
                size_t block = access % 3 == 0   ? 0
                               : access % 3 == 1 ? reader.block_count() / 2
                                                 : reader.block_count() - 1;
                auto begin = std::chrono::steady_clock::now();
                auto bytes = reader.decode_block(block);
                if (measure)
                    decode_ns += wordzip_session::elapsed(begin);
                decoded += bytes.size();
                checksum = (checksum ^ crc(bytes)) * 1099511628211ull;
                if (!visited[block]) {
                    requested += reader.record(block).encoded;
                    visited[block] = true;
                }
            }
            struct rusage usage{};
            getrusage(RUSAGE_SELF, &usage);
            std::string json =
                "{\"timing_enabled\":" + std::string(measure ? "true" : "false") +
                ",\"prepare_ns\":" + std::to_string(preparation_ns) +
                ",\"decode_256_ns\":" + std::to_string(decode_ns) +
                ",\"access_count\":256,\"decoded_bytes\":" + std::to_string(decoded) +
                ",\"checksum\":\"" + std::to_string(checksum) +
                "\",\"frame_bytes\":" + std::to_string(reader.frame_bytes()) +
                ",\"metadata_bytes\":" + std::to_string(reader.metadata_bytes()) +
                ",\"prepared_model_bytes\":" + std::to_string(reader.model_bytes()) +
                ",\"prepared_model_live_bytes\":" + std::to_string(reader.model_bytes(false)) +
                ",\"fixed_crc_table_bytes\":1024" +
                ",\"distinct_logical_input_bytes\":" + std::to_string(requested) +
                ",\"peakrss_kib\":" + std::to_string(usage.ru_maxrss) + "}\n";
            write(argv[3], Bytes(json.begin(), json.end()));
            std::cout << json;
        } else {
            throw std::runtime_error("reader unknown operation");
        }
    } catch (const std::exception &error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
