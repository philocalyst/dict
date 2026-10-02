// GWT1 prepared reader. The native v4 implementation is linked as the frozen
// WPG2 C ABI: prepare model/deltas once and decode only a requested page Job.
#include "geometry_residual.h"
#include "../../word_constructions/prepared_jobs.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr size_t HEADER = 48;
constexpr size_t PAGE = geometry_residual::page_bytes;
constexpr size_t MAX_RAW = 64 * 1024 * 1024;
constexpr size_t MAX_FRAME = 64 * 1024 * 1024; // frozen prepared_jobs limit
constexpr size_t MAX_PAGES = MAX_RAW / PAGE;
constexpr size_t MAX_ARCHIVE = HEADER + 12 * MAX_PAGES + 1533 + MAX_FRAME +
                               2 * MAX_RAW + 4 * MAX_PAGES;

uint32_t crc_update(uint32_t crc, const unsigned char *data, size_t len) {
    static const auto table = [] {
        struct Table { uint32_t values[256]; } result{};
        for (unsigned i = 0; i < 256; ++i) {
            uint32_t x = i;
            for (unsigned j = 0; j < 8; ++j)
                x = (x >> 1) ^ ((x & 1) ? 0xedb88320u : 0u);
            result.values[i] = x;
        }
        return result;
    }();
    for (size_t i = 0; i < len; ++i)
        crc = table.values[(crc ^ data[i]) & 255] ^ (crc >> 8);
    return crc;
}
uint32_t crc32(const unsigned char *data, size_t len) {
    return crc_update(0xffffffffu, data, len) ^ 0xffffffffu;
}
uint32_t crc32(std::string_view bytes) {
    return crc32(reinterpret_cast<const unsigned char *>(bytes.data()), bytes.size());
}
uint32_t u32(const unsigned char *p) {
    return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24;
}
uint64_t u64(const unsigned char *p) {
    return uint64_t(u32(p)) | uint64_t(u32(p + 4)) << 32;
}
size_t decimal(const char *s) {
    if (!*s) throw std::runtime_error("empty decimal");
    size_t value = 0;
    for (; *s; ++s) {
        const unsigned digit = static_cast<unsigned char>(*s) - '0';
        if (digit > 9 || value > (std::numeric_limits<size_t>::max() - digit) / 10)
            throw std::runtime_error("decimal overflow");
        value = 10 * value + digit;
    }
    return value;
}
class FileMap {
    const unsigned char *data_ = nullptr;
    size_t size_ = 0;
public:
    explicit FileMap(const std::string& path) {
        int fd = open(path.c_str(), O_RDONLY | O_CLOEXEC);
        if (fd < 0) throw std::runtime_error("open archive failed");
        struct stat status{};
        if (fstat(fd, &status) != 0 || !S_ISREG(status.st_mode) ||
            status.st_size < static_cast<off_t>(HEADER) ||
            static_cast<uint64_t>(status.st_size) > MAX_ARCHIVE) {
            close(fd);
            throw std::runtime_error("archive file size bound");
        }
        size_ = static_cast<size_t>(status.st_size);
        void *mapping = mmap(nullptr, size_, PROT_READ, MAP_PRIVATE, fd, 0);
        close(fd);
        if (mapping == MAP_FAILED) throw std::runtime_error("archive mmap failed");
        data_ = static_cast<const unsigned char *>(mapping);
    }
    ~FileMap() { if (data_) munmap(const_cast<unsigned char *>(data_), size_); }
    FileMap(const FileMap&) = delete;
    FileMap& operator=(const FileMap&) = delete;
    const unsigned char *data() const { return data_; }
    size_t size() const { return size_; }
};
void write_file(const std::string& path, std::string_view bytes) {
    std::ofstream stream(path, std::ios::binary);
    if (!stream) throw std::runtime_error("open output failed");
    stream.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
    if (!stream) throw std::runtime_error("write output failed");
}
struct PageIndex {
    uint32_t events, flags_length, raw_crc;
    size_t flags_offset;
};
struct Archive {
    FileMap bytes;
    std::vector<PageIndex> pages;
    std::unique_ptr<geometry_residual::Model> model;
    size_t raw_size = 0, frame_at = 0, frame_size = 0, flags_at = 0;
    size_t index_bytes = 0, model_bytes = 0, flags_bytes = 0;
    uint32_t source_crc = 0, normalized_crc = 0;
    unsigned width = 0;

    explicit Archive(const std::string& path) : bytes(path) {
        if (bytes.size() < HEADER || std::memcmp(bytes.data(), "GWT1", 4) != 0 || u32(bytes.data()+4) != 1)
            throw std::runtime_error("GWT1 header magic/version");
        width = u32(bytes.data()+8);
        const uint64_t raw = u64(bytes.data()+12);
        const size_t count = u32(bytes.data()+20);
        frame_size = u32(bytes.data()+24);
        flags_bytes = u32(bytes.data()+28);
        model_bytes = u32(bytes.data()+32);
        source_crc = u32(bytes.data()+36);
        normalized_crc = u32(bytes.data()+40);
        const uint32_t header_crc = u32(bytes.data()+44);
        if (width == 0 || width > 4096 || raw > MAX_RAW ||
            count != (raw + PAGE - 1) / PAGE || count > MAX_PAGES ||
            frame_size > MAX_FRAME || model_bytes < 3 || model_bytes > 1533)
            throw std::runtime_error("GWT1 resource or page geometry");
        raw_size = static_cast<size_t>(raw);
        index_bytes = 12 * count;
        const uint64_t exact = uint64_t(HEADER) + index_bytes + model_bytes + frame_size + flags_bytes;
        if (exact != bytes.size()) throw std::runtime_error("GWT1 segment lengths");
        const size_t model_at = HEADER + index_bytes;
        frame_at = model_at + model_bytes;
        flags_at = frame_at + frame_size;
        const unsigned char zero[4]{};
        uint32_t crc = crc_update(0xffffffffu, bytes.data(), 44);
        crc = crc_update(crc, zero, 4);
        crc = crc_update(crc, bytes.data() + HEADER, index_bytes + model_bytes);
        if ((crc ^ 0xffffffffu) != header_crc)
            throw std::runtime_error("GWT1 header CRC");
        pages.reserve(count);
        size_t cumulative_flags = 0;
        for (size_t i = 0; i < count; ++i) {
            const auto *entry = bytes.data() + HEADER + i * 12;
            const uint32_t events = u32(entry);
            const uint32_t flag_length = u32(entry + 4);
            const uint32_t raw_crc = u32(entry + 8);
            const size_t page_length = std::min(PAGE, raw_size - i * PAGE);
            if (events > page_length || flag_length < 4 ||
                flag_length - 4 > 2 * events || flag_length > flags_bytes - cumulative_flags)
                throw std::runtime_error("GWT1 page index bound");
            pages.push_back({events, flag_length, raw_crc, cumulative_flags});
            cumulative_flags += flag_length;
        }
        if (cumulative_flags != flags_bytes)
            throw std::runtime_error("GWT1 flags sum");
        model = std::make_unique<geometry_residual::Model>(std::string_view(
            reinterpret_cast<const char *>(bytes.data() + model_at), model_bytes));
    }
    const unsigned char *frame() const { return bytes.data() + frame_at; }
    std::string_view flags(size_t page) const {
        const auto& entry = pages[page];
        return {reinterpret_cast<const char *>(bytes.data()+flags_at+entry.flags_offset), entry.flags_length};
    }
};

struct Reader {
    Archive archive;
    void *prepared = nullptr;
    size_t normalized_bytes = 0, native_jobs = 0, model_reserved = 0, job_directory = 0;
    size_t decoder_live = 0, decoder_peak = 0, decoder_limit = 0;
    size_t page_scratch_peak = 0;
    explicit Reader(const std::string& path) : archive(path) {
        if (wpg_prepare(archive.frame(), archive.frame_size, &prepared))
            throw std::runtime_error("native v4 preparation failed");
        if (wpg_stats(prepared, &normalized_bytes, &native_jobs, &model_reserved, &job_directory) ||
            wpg_budget_stats(prepared, &decoder_live, &decoder_peak, &decoder_limit) ||
            normalized_bytes != archive.raw_size || native_jobs != archive.pages.size() ||
            decoder_peak > decoder_limit) {
            wpg_close(prepared); prepared = nullptr;
            throw std::runtime_error("native normalized length mismatch");
        }
    }
    ~Reader() { wpg_close(prepared); }
    Reader(const Reader&) = delete;
    Reader& operator=(const Reader&) = delete;

    struct Page { std::string bytes, normalized; size_t payload_jobs; };
    Page read(size_t index) {
        if (index >= archive.pages.size()) throw std::runtime_error("page index");
        const size_t length = std::min(PAGE, archive.raw_size - index * PAGE);
        std::string normalized(length, '\0');
        size_t jobs = 0;
        if (wpg_read(prepared, index * PAGE, length,
                     reinterpret_cast<unsigned char *>(normalized.data()), length, &jobs))
            throw std::runtime_error("native v4 page decode failed");
        if (jobs != 1) throw std::runtime_error("native v4 page Job alignment");
        const auto& entry = archive.pages[index];
        std::string raw = geometry_residual::realize(normalized, archive.flags(index),
                                                     *archive.model, entry.events, archive.width);
        page_scratch_peak = std::max(page_scratch_peak, normalized.size() + raw.size());
        if (raw.size() != length || crc32(raw) != entry.raw_crc)
            throw std::runtime_error("GWT1 raw page CRC/length");
        return {std::move(raw), std::move(normalized), jobs};
    }
    void decode_all(const std::string& path) {
        std::vector<char> temp(path.begin(), path.end());
        const std::string suffix = ".tmp.XXXXXX";
        temp.insert(temp.end(), suffix.begin(), suffix.end());
        temp.push_back('\0');
        const int fd = mkstemp(temp.data());
        if (fd < 0) throw std::runtime_error("temporary output open failed");
        std::FILE *out = fdopen(fd, "wb");
        if (!out) { close(fd); std::remove(temp.data()); throw std::runtime_error("fdopen failed"); }
        try {
            uint32_t raw_crc = 0xffffffffu, norm_crc = 0xffffffffu;
            for (size_t i = 0; i < archive.pages.size(); ++i) {
                Page page = read(i);
                if (std::fwrite(page.bytes.data(), 1, page.bytes.size(), out) != page.bytes.size())
                    throw std::runtime_error("output write failed");
                raw_crc = crc_update(raw_crc,
                    reinterpret_cast<const unsigned char *>(page.bytes.data()), page.bytes.size());
                norm_crc = crc_update(norm_crc,
                    reinterpret_cast<const unsigned char *>(page.normalized.data()), page.normalized.size());
            }
            if ((raw_crc ^ 0xffffffffu) != archive.source_crc ||
                (norm_crc ^ 0xffffffffu) != archive.normalized_crc)
                throw std::runtime_error("GWT1 global CRC");
            if (std::fclose(out) != 0) { out = nullptr; throw std::runtime_error("output close failed"); }
            out = nullptr;
            if (std::rename(temp.data(), path.c_str()) != 0)
                throw std::runtime_error("atomic output publish failed");
        } catch (...) {
            if (out) std::fclose(out);
            std::remove(temp.data());
            throw;
        }
    }
};
long long elapsed_ns(std::chrono::steady_clock::time_point since) {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now() - since).count();
}
long long rss_peak_kb() {
    struct rusage usage{};
    return getrusage(RUSAGE_SELF, &usage) == 0 ? usage.ru_maxrss : -1;
}
} // namespace

int main(int argc, char **argv) {
    try {
        if (argc < 4)
            throw std::runtime_error("usage: prepared_geometry decode|query|bench|inspect ARCHIVE OUTPUT [--index N] [--measure 1 --quiet-gate WORDZIP-READER-QUIET]");
        const std::string operation(argv[1]), input(argv[2]), output(argv[3]);
        size_t index = 0;
        bool measured = false, quiet = false;
        for (int i = 4; i < argc; i += 2) {
            if (i + 1 >= argc) throw std::runtime_error("missing option value");
            const std::string option(argv[i]), value(argv[i+1]);
            if (option == "--index") index = decimal(argv[i+1]);
            else if (option == "--measure") {
                if (value != "0" && value != "1") throw std::runtime_error("measure value");
                measured = value == "1";
            } else if (option == "--quiet-gate") quiet = value == "WORDZIP-READER-QUIET";
            else throw std::runtime_error("unknown option");
        }
        if (measured && !quiet) throw std::runtime_error("quiet timing gate");
        const auto began = std::chrono::steady_clock::now();
        Reader reader(input);
        const auto prepare_ns = measured ? elapsed_ns(began) : 0;
        if (operation == "inspect") {
            std::ofstream out(output);
            if (!out) throw std::runtime_error("open inspect output failed");
            out << "{\"protocol\":\"GWT1-PREPARED-INSPECT/1\""
                << ",\"verified_scope\":\"outer header/index/tree and native model/Jobs; payload and source CRC require decode\""
                << ",\"frame_bytes\":" << reader.archive.bytes.size()
                << ",\"raw_bytes\":" << reader.archive.raw_size
                << ",\"normalized_bytes\":" << reader.normalized_bytes
                << ",\"page_bytes\":" << PAGE
                << ",\"pages\":" << reader.archive.pages.size()
                << ",\"native_jobs\":" << reader.native_jobs
                << ",\"header_bytes\":" << HEADER
                << ",\"index_bytes\":" << reader.archive.index_bytes
                << ",\"geometry_model_bytes\":" << reader.archive.model_bytes
                << ",\"flags_bytes\":" << reader.archive.flags_bytes
                << ",\"native_frame_bytes\":" << reader.archive.frame_size
                << ",\"prepare_ns\":" << prepare_ns
                << ",\"archive_mapped_bytes\":" << reader.archive.bytes.size()
                << ",\"model_reserved_bytes\":" << reader.model_reserved
                << ",\"job_directory_bytes\":" << reader.job_directory
                << ",\"decoder_live_bytes\":" << reader.decoder_live
                << ",\"decoder_peak_bytes\":" << reader.decoder_peak
                << ",\"decoder_limit_bytes\":" << reader.decoder_limit
                << ",\"rss_peak_kb\":" << rss_peak_kb() << "}\n";
            out.close();
            if (!out) throw std::runtime_error("inspect output write failed");
            std::ifstream back(output);
            std::cout << back.rdbuf();
        } else if (operation == "query") {
            const auto read_start = std::chrono::steady_clock::now();
            auto page = reader.read(index);
            const auto read_ns = measured ? elapsed_ns(read_start) : 0;
            write_file(output, page.bytes);
            std::cout << "{\"page\":" << index << ",\"bytes\":" << page.bytes.size()
                      << ",\"payload_jobs\":" << page.payload_jobs
                      << ",\"prepare_ns\":" << prepare_ns << ",\"query_ns\":" << read_ns
                      << ",\"index_bytes\":" << reader.archive.index_bytes
                      << ",\"geometry_model_bytes\":" << reader.archive.model_bytes
                      << ",\"flags_bytes\":" << reader.archive.flags_bytes
                      << ",\"native_frame_bytes\":" << reader.archive.frame_size
                      << ",\"archive_mapped_bytes\":" << reader.archive.bytes.size()
                      << ",\"model_reserved_bytes\":" << reader.model_reserved
                      << ",\"job_directory_bytes\":" << reader.job_directory
                      << ",\"decoder_live_bytes\":" << reader.decoder_live
                      << ",\"decoder_peak_bytes\":" << reader.decoder_peak
                      << ",\"decoder_limit_bytes\":" << reader.decoder_limit
                      << ",\"page_scratch_peak_bytes\":" << reader.page_scratch_peak
                      << ",\"native_job_stack_bytes\":65536,\"rss_peak_kb\":" << rss_peak_kb() << "}\n";
        } else if (operation == "decode") {
            const auto read_start = std::chrono::steady_clock::now();
            reader.decode_all(output);
            std::cout << "{\"frame_bytes\":" << reader.archive.bytes.size()
                      << ",\"raw_bytes\":" << reader.archive.raw_size
                      << ",\"pages\":" << reader.archive.pages.size()
                      << ",\"native_jobs\":" << reader.native_jobs
                      << ",\"prepare_ns\":" << prepare_ns
                      << ",\"decode_ns\":" << (measured ? elapsed_ns(read_start) : 0)
                      << ",\"index_bytes\":" << reader.archive.index_bytes
                      << ",\"geometry_model_bytes\":" << reader.archive.model_bytes
                      << ",\"flags_bytes\":" << reader.archive.flags_bytes
                      << ",\"native_frame_bytes\":" << reader.archive.frame_size
                      << ",\"archive_mapped_bytes\":" << reader.archive.bytes.size()
                      << ",\"model_reserved_bytes\":" << reader.model_reserved
                      << ",\"job_directory_bytes\":" << reader.job_directory
                      << ",\"decoder_live_bytes\":" << reader.decoder_live
                      << ",\"decoder_peak_bytes\":" << reader.decoder_peak
                      << ",\"decoder_limit_bytes\":" << reader.decoder_limit
                      << ",\"page_scratch_peak_bytes\":" << reader.page_scratch_peak
                      << ",\"native_job_stack_bytes\":65536,\"rss_peak_kb\":" << rss_peak_kb() << "}\n";
        } else if (operation == "bench") {
            if (reader.archive.pages.empty()) throw std::runtime_error("empty benchmark");
            const auto query_start = std::chrono::steady_clock::now();
            uint64_t checksum = 1469598103934665603ull;
            size_t total_bytes = 0, total_jobs = 0;
            for (size_t access = 0; access < 256; ++access) {
                const size_t chosen = access % 3 == 0 ? 0 :
                    (access % 3 == 1 ? reader.archive.pages.size()/2 : reader.archive.pages.size()-1);
                auto page = reader.read(chosen);
                checksum = (checksum ^ crc32(page.bytes)) * 1099511628211ull;
                total_bytes += page.bytes.size();
                total_jobs += page.payload_jobs;
            }
            const auto query_ns = measured ? elapsed_ns(query_start) : 0;
            std::ofstream out(output);
            if (!out) throw std::runtime_error("open benchmark output failed");
            out << "{\"protocol\":\"GWT1-PREPARED-PAGE/1\",\"timing_enabled\":"
                << (measured ? "true" : "false")
                << ",\"frame_bytes\":" << reader.archive.bytes.size()
                << ",\"raw_bytes\":" << reader.archive.raw_size
                << ",\"normalized_bytes\":" << reader.normalized_bytes
                << ",\"page_bytes\":" << PAGE
                << ",\"pages\":" << reader.archive.pages.size()
                << ",\"native_jobs\":" << reader.native_jobs
                << ",\"prepare_ns\":" << prepare_ns
                << ",\"decode_256_ns\":" << query_ns
                << ",\"access_count\":256,\"decoded_bytes\":" << total_bytes
                << ",\"decoded_jobs\":" << total_jobs
                << ",\"checksum\":" << checksum
                << ",\"index_bytes\":" << reader.archive.index_bytes
                << ",\"geometry_model_bytes\":" << reader.archive.model_bytes
                << ",\"flags_bytes\":" << reader.archive.flags_bytes
                << ",\"native_frame_bytes\":" << reader.archive.frame_size
                << ",\"archive_mapped_bytes\":" << reader.archive.bytes.size()
                << ",\"model_reserved_bytes\":" << reader.model_reserved
                << ",\"job_directory_bytes\":" << reader.job_directory
                << ",\"decoder_live_bytes\":" << reader.decoder_live
                << ",\"decoder_peak_bytes\":" << reader.decoder_peak
                << ",\"decoder_limit_bytes\":" << reader.decoder_limit
                << ",\"page_scratch_peak_bytes\":" << reader.page_scratch_peak
                << ",\"native_job_stack_bytes\":65536,\"rss_peak_kb\":" << rss_peak_kb()
                << ",\"accounting\":\"prepare maps the archive and prepares native model deltas and immutable Jobs; query decodes only one payload Job, reads one residual flag segment, reconstructs one page and checks its CRC\"}\n";
            out.close();
            if (!out) throw std::runtime_error("benchmark output write failed");
            std::ifstream back(output);
            std::cout << back.rdbuf();
        } else throw std::runtime_error("unknown operation");
    } catch (const std::exception& error) {
        std::cerr << "GWT1 reader: " << error.what() << '\n';
        return 1;
    }
}
