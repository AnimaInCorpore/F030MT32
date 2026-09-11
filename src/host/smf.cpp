#include "smf.h"

#include <algorithm>
#include <cstdio>
#include <memory>
#include <stdexcept>

namespace f030mt32 {
namespace {
using Bytes = std::vector<std::uint8_t>;
constexpr std::uint32_t MAX_SAMPLES = 1800U * 32000;
constexpr std::size_t MAX_EVENTS = 65536;

struct Reader {
    const Bytes &data;
    std::size_t pos, end;
    std::uint8_t byte() {
        if (pos == end) throw std::runtime_error("Truncated MIDI file");
        return data[pos++];
    }
    std::uint32_t be(unsigned n) {
        std::uint32_t v = 0;
        while (n--) v = (v << 8) | byte();
        return v;
    }
    std::uint32_t vlq() {
        std::uint32_t v = 0;
        for (int i = 0; i < 4; ++i) {
            const auto b = byte();
            v = (v << 7) | (b & 127);
            if (!(b & 128)) return v;
        }
        throw std::runtime_error("MIDI variable-length value exceeds four bytes");
    }
    Bytes take(std::uint32_t n) {
        if (n > end - pos) throw std::runtime_error("MIDI event exceeds its track");
        Bytes b(data.begin() + pos, data.begin() + pos + n);
        pos += n;
        return b;
    }
};

void append(MidiSong &song, MidiEvent event) {
    if (song.events.size() == MAX_EVENTS) throw std::runtime_error("MIDI exceeds 65536 events");
    song.events.push_back(std::move(event));
}

void track(Reader r, MidiSong &song) {
    std::uint64_t tick = 0;
    std::uint8_t running = 0;
    Bytes sysex;
    bool ended = false;
    while (r.pos < r.end) {
        tick += r.vlq();
        if (tick > 0xffffffffU) throw std::runtime_error("MIDI tick count overflow");
        auto status = r.byte();
        if (status < 128) {
            if (!running) throw std::runtime_error("MIDI running status without a status byte");
            --r.pos;
            status = running;
        }
        MidiEvent e;
        e.tick = tick;
        if (status < 0xf0) {
            if (!sysex.empty()) throw std::runtime_error("Channel event inside unfinished SysEx");
            running = status;
            e.bytes.push_back(status);
            const unsigned count = (status & 0xe0) == 0xc0 ? 1 : 2;
            for (unsigned i = 0; i < count; ++i) {
                const auto b = r.byte();
                if (b >= 128) throw std::runtime_error("Status byte in MIDI data");
                e.bytes.push_back(b);
            }
        } else if (status == 0xff) {
            running = 0;
            const auto type = r.byte();
            const auto data = r.take(r.vlq());
            if (type == 0x2f) {
                if (!data.empty() || !sysex.empty() || r.pos != r.end)
                    throw std::runtime_error("Invalid end-of-track event");
                ended = true;
            } else if (type == 0x51) {
                if (data.size() != 3) throw std::runtime_error("Invalid MIDI tempo length");
                e.tempo = (data[0] << 16) | (data[1] << 8) | data[2];
                if (!e.tempo) throw std::runtime_error("Zero MIDI tempo");
            } else if (type == 0x21 && (data.size() != 1 || data[0] != 0)) {
                throw std::runtime_error("Multiple MIDI output ports are unsupported");
            }
        } else if (status == 0xf0 || status == 0xf7) {
            running = 0;
            if (status == 0xf0) {
                if (!sysex.empty()) throw std::runtime_error("Nested MIDI SysEx");
                sysex.push_back(0xf0);
            } else if (sysex.empty()) {
                throw std::runtime_error("Escaped F7 events require a preceding SysEx");
            }
            auto data = r.take(r.vlq());
            if (data.size() > 32768 - sysex.size()) throw std::runtime_error("SysEx exceeds 32768 bytes");
            for (std::size_t i = 0; i < data.size(); ++i) {
                if (data[i] >= 128 && !(data[i] == 0xf7 && i + 1 == data.size()))
                    throw std::runtime_error("Invalid byte in SysEx");
            }
            sysex.insert(sysex.end(), data.begin(), data.end());
            if (sysex.back() == 0xf7) e.bytes.swap(sysex);
        } else {
            throw std::runtime_error("Unsupported SMF system event");
        }
        // Keep metadata timestamps: a silent track or delayed EOT sets song length.
        append(song, std::move(e));
    }
    if (!ended) throw std::runtime_error("MIDI track has no end-of-track event");
}
}

Bytes readBytes(const std::string &path, std::size_t maximum) {
    std::unique_ptr<std::FILE, int (*)(std::FILE *)> file(std::fopen(path.c_str(), "rb"), std::fclose);
    if (!file) throw std::runtime_error("Cannot open input: " + path);
    if (std::fseek(file.get(), 0, SEEK_END)) throw std::runtime_error("Cannot seek input: " + path);
    const auto size = std::ftell(file.get());
    if (size <= 0 || static_cast<unsigned long>(size) > maximum) throw std::runtime_error("Invalid input size: " + path);
    Bytes data(static_cast<std::size_t>(size));
    if (std::fseek(file.get(), 0, SEEK_SET) || std::fread(data.data(), 1, data.size(), file.get()) != data.size())
        throw std::runtime_error("Cannot read input: " + path);
    return data;
}

MidiSong readSMF(const std::string &path) {
    const auto data = readBytes(path, 4 * 1024 * 1024);
    Reader r{data, 0, data.size()};
    if (r.be(4) != 0x4d546864) throw std::runtime_error("Missing MThd header");
    const auto headerSize = r.be(4);
    if (headerSize < 6 || headerSize > r.end - r.pos) throw std::runtime_error("Invalid MIDI header length");
    const auto format = r.be(2), tracks = r.be(2), division = r.be(2);
    if (format > 1 || !tracks || tracks > 256 || (format == 0 && tracks != 1))
        throw std::runtime_error("Expected SMF format 0 or 1, with 1 to 256 tracks");
    if (!division) throw std::runtime_error("Zero MIDI time division");
    r.pos += headerSize - 6;
    MidiSong song;
    for (unsigned i = 0; i < tracks; ++i) {
        if (r.be(4) != 0x4d54726b) throw std::runtime_error("Missing MTrk chunk");
        const auto length = r.be(4);
        if (length > r.end - r.pos) throw std::runtime_error("Track exceeds MIDI file");
        track(Reader{data, r.pos, r.pos + length}, song);
        r.pos += length;
    }
    if (r.pos != r.end) throw std::runtime_error("Trailing data after MIDI tracks");
    std::stable_sort(song.events.begin(), song.events.end(), [](const MidiEvent &a, const MidiEvent &b) {
        return a.tick < b.tick;
    });
    std::uint64_t numerator = 2000000, denominator = division * 125;
    const bool smpte = (division & 0x8000) != 0;
    if (smpte) {
        const int fps = 256 - (division >> 8);
        if ((fps != 24 && fps != 25 && fps != 29 && fps != 30) || !(division & 255))
            throw std::runtime_error("Invalid SMPTE division");
        numerator = fps == 29 ? 32000ULL * 1001 : 32000;
        denominator = (fps == 29 ? 30000 : fps) * (division & 255);
    }
    std::uint64_t lastTick = 0, samples = 0, remainder = 0;
    for (auto &event : song.events) {
        const auto elapsed = (event.tick - lastTick) * numerator + remainder;
        samples += elapsed / denominator;
        remainder = elapsed % denominator;
        if (samples > MAX_SAMPLES) throw std::runtime_error("MIDI exceeds 30 minutes");
        event.sample = static_cast<std::uint32_t>(samples);
        lastTick = event.tick;
        if (event.tempo && !smpte) numerator = event.tempo * 4ULL;
    }
    song.endSample = static_cast<std::uint32_t>(samples);
    return song;
}
}
