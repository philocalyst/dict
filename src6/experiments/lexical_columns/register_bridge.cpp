// Reuse the independently audited exact inverse; no second implementation.
// The donor registers and opcodes are paid in the stream, with a fixed bound.
#define WREG_NO_MAIN
#include "../word_constructions/register_decode.cpp"
#include <cstddef>
#include <cstring>
extern "C" int lex_register_inverse(unsigned mode, const unsigned char* source,
    std::size_t input_length, unsigned char* output, std::size_t output_capacity,
    std::size_t* output_length) noexcept {
    if (!output_length || input_length > 131072 || output_capacity > 262144 ||
        (mode != 1 && mode != 2)) return -1;
    try {
        std::string stage(reinterpret_cast<const char*>(source), input_length);
        if (mode == 2) stage = process_segment(stage, true);
        stage = process_segment(stage, false);
        if (stage.size() > output_capacity) return -2;
        std::memcpy(output, stage.data(), stage.size());
        *output_length = stage.size();
        return 0;
    } catch (...) { return -3; }
}
