#ifndef F030MT32_SMF_H
#define F030MT32_SMF_H

#include <cstdint>
#include <string>
#include <vector>

namespace f030mt32 {

struct MidiEvent {
    std::uint64_t tick = 0;
    std::uint32_t sample = 0; // native 32 kHz time, independent of the codec
    std::uint32_t tempo = 0;
    std::vector<std::uint8_t> bytes;
};

struct MidiSong {
    std::vector<MidiEvent> events;
    std::uint32_t endSample = 0;
};

// SMF format 0/1, PPQN or SMPTE time, with deterministic track-order ties.
// Throws std::runtime_error for malformed or unsupported input.
MidiSong readSMF(const std::string &path);
std::vector<std::uint8_t> readBytes(const std::string &path, std::size_t maximum);

}
#endif
