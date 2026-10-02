// One native process for either frozen WordFrontier wire format. The reader
// implementations and their budget, inverse, CRC and publication paths are
// reused verbatim; encoding and model selection remain encoder-only work.
#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
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
#include "../word_constructions/prepared_jobs.h"
#include "../wordgrammar/geometry/geometry_residual.h"

namespace wordfrontier_wpg {
#define main run_cli
#include "wpg_cli.inc"
#undef main
}
namespace wordfrontier_gwt {
#define main run_cli
#include "gwt_cli.inc"
#undef main
}

int main(int argc, char **argv) {
    try {
        if (argc < 4) throw std::runtime_error(
            "usage: wordfrontier-decode decode|query|bench ARCHIVE OUTPUT "
            "[--index N --measure 0|1 --quiet-gate WORDZIP-READER-QUIET]");
        const std::string operation(argv[1]);
        if (operation != "decode" && operation != "query" && operation != "bench")
            throw std::runtime_error("unknown operation");
        for (int i = 4; i < argc; i += 2) {
            if (i + 1 >= argc) throw std::runtime_error("missing option value");
            const std::string option(argv[i]), value(argv[i + 1]);
            if (option == "--index") {
                if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos)
                    throw std::runtime_error("invalid page index");
            } else if (option == "--measure") {
                if (value != "0" && value != "1") throw std::runtime_error("measure value");
            } else if (option != "--quiet-gate") throw std::runtime_error("unknown option");
        }
        struct stat info;
        if (stat(argv[2], &info) || !S_ISREG(info.st_mode) || info.st_size < 4 ||
            static_cast<uint64_t>(info.st_size) > 3ull * 64 * 1024 * 1024 + 65536)
            throw std::runtime_error("regular bounded archive required");
        char magic[4];
        std::ifstream input(argv[2], std::ios::binary);
        if (!input.read(magic, sizeof magic)) throw std::runtime_error("short archive magic");
        if (!std::memcmp(magic, "WPG2", sizeof magic))
            return wordfrontier_wpg::run_cli(argc, argv);
        if (!std::memcmp(magic, "GWT1", sizeof magic))
            return wordfrontier_gwt::run_cli(argc, argv);
        throw std::runtime_error("unsupported archive magic");
    } catch (const std::exception& error) {
        std::fprintf(stderr, "wordfrontier-decode: %s\n", error.what());
        return 1;
    }
}
