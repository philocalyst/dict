// Integer-only geometry residual inverse, independently testable from GWT1.
#include "geometry_residual.h"

#include <fstream>
#include <iostream>
#include <iterator>
#include <limits>
#include <stdexcept>

static std::string read_file(const char *path, size_t limit) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) throw std::runtime_error("open input failed");
    const auto size = stream.tellg();
    if (size < 0 || static_cast<uint64_t>(size) > limit)
        throw std::runtime_error("input size bound");
    std::string result(static_cast<size_t>(size), '\0');
    stream.seekg(0);
    if (!result.empty()) stream.read(result.data(), static_cast<std::streamsize>(result.size()));
    if (!stream && !result.empty()) throw std::runtime_error("read input failed");
    return result;
}

static size_t decimal(const char *s) {
    if (!*s) throw std::runtime_error("empty decimal");
    size_t value = 0;
    for (; *s; ++s) {
        if (*s < '0' || *s > '9' || value > (std::numeric_limits<size_t>::max() - (*s - '0')) / 10)
            throw std::runtime_error("decimal bound");
        value = value * 10 + (*s - '0');
    }
    return value;
}

int main(int argc, char **argv) {
    try {
        if (argc != 7)
            throw std::runtime_error("usage: geometry_decode NORMALIZED FLAGS MODEL EVENT_COUNT WIDTH OUTPUT");
        const auto normalized = read_file(argv[1], geometry_residual::page_bytes);
        const auto flags = read_file(argv[2], 2 * geometry_residual::page_bytes + 4);
        const auto model_wire = read_file(argv[3], 1533);
        const geometry_residual::Model model(model_wire);
        const auto output = geometry_residual::realize(
            normalized, flags, model, decimal(argv[4]), static_cast<unsigned>(decimal(argv[5])));
        std::ofstream stream(argv[6], std::ios::binary);
        if (!stream) throw std::runtime_error("open output failed");
        stream.write(output.data(), static_cast<std::streamsize>(output.size()));
        if (!stream) throw std::runtime_error("write output failed");
        std::cout << "{\"bytes\":" << output.size() << "}\n";
    } catch (const std::exception &error) {
        std::cerr << "geometry residual: " << error.what() << '\n';
        return 1;
    }
}
