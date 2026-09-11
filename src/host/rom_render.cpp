// Full ROM-backed reference renderer, shared by the workstation and Falcon.
// Deliberately renders to disk before playback: this is not a real-time port.
#include "smf.h"
#include "mt32emu.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <memory>
#include <stdexcept>

#ifdef __MINT__
// Munt's render and resampler stack needs more than the TOS C runtime default.
long _stksize = 65536;
#endif

namespace {
using namespace MT32Emu;
constexpr double CODEC_RATE = 25175000.0 / 768.0;

struct Reporter : ReportHandler {
    void printDebug(const char *, va_list) override {}
    void showLCDMessage(const char *message) override { std::printf("LCD: %s\n", message); }
};

struct Rom {
    std::vector<std::uint8_t> data;
    ArrayFile file;
    const ROMImage *image = nullptr;
    Rom(const char *name, ROMInfo::Type type) : data(f030mt32::readBytes(name, 1024 * 1024)), file(data.data(), data.size()) {
        image = ROMImage::makeROMImage(&file);
        const auto info = image ? image->getROMInfo() : nullptr;
        if (!info || info->type != type || info->pairType != ROMInfo::Full) {
            ROMImage::freeROMImage(image);
            image = nullptr;
            throw std::runtime_error(std::string("Unrecognised or incomplete ROM: ") + name);
        }
        std::printf("ROM: %s\n", info->description);
    }
    ~Rom() { if (image) ROMImage::freeROMImage(image); }
};

struct Output {
    std::FILE *file;
    bool digital;
    std::uint32_t frames = 0;
    Output(const char *path, bool native) : file(std::fopen(path, "wb")), digital(native) {
        if (!file) throw std::runtime_error(std::string("Cannot create output: ") + path);
        // An unfinished file has a zero frame count and is rejected by the player.
        unsigned char header[44] = {};
        if (std::fwrite(header, 1, digital ? 44 : 16, file) != (digital ? 44U : 16U)) {
            std::fclose(file);
            throw std::runtime_error("Cannot write output header");
        }
    }
    ~Output() { if (file) std::fclose(file); }
    void write(const Bit16s *samples, unsigned count) {
        unsigned char bytes[512 * 4];
        for (unsigned i = 0; i < 2 * count; ++i) {
            const auto s = static_cast<unsigned short>(samples[i]);
            bytes[2 * i + (digital ? 0 : 1)] = s & 255;
            bytes[2 * i + (digital ? 1 : 0)] = s >> 8;
        }
        if (std::fwrite(bytes, 4, count, file) != count) throw std::runtime_error("Audio write failed (disk full?)");
        frames += count;
    }
    void finish() {
        if (std::fseek(file, 0, SEEK_SET)) throw std::runtime_error("Cannot seek output header");
        unsigned char h[44] = {};
        const auto put = [&](unsigned offset, std::uint32_t value, unsigned n) {
            for (unsigned i = 0; i < n; ++i) h[offset + (digital ? i : n - 1 - i)] = value >> (8 * i);
        };
        if (digital) {
            std::memcpy(h, "RIFF", 4); put(4, 36 + frames * 4, 4);
            std::memcpy(h + 8, "WAVEfmt ", 8); put(16, 16, 4); put(20, 1, 2); put(22, 2, 2);
            put(24, 32000, 4); put(28, 128000, 4); put(32, 4, 2); put(34, 16, 2);
            std::memcpy(h + 36, "data", 4); put(40, frames * 4, 4);
        } else {
            std::memcpy(h, "F32P", 4); put(4, 25175000, 4); put(8, 768, 4); put(12, frames, 4);
        }
        const unsigned size = digital ? 44 : 16;
        if (std::fwrite(h, 1, size, file) != size) throw std::runtime_error("Cannot finalise audio header");
        const int status = std::fclose(file);
        file = nullptr;
        if (status) throw std::runtime_error("Cannot close audio output");
    }
};

int render(int argc, char **argv) {
    bool digital = false;
    unsigned partials = 32, tail = 4;
    int arg = 1;
    while (arg < argc && argv[arg][0] == '-') {
        if (!std::strcmp(argv[arg], "--digital")) { digital = true; ++arg; }
        else if ((!std::strcmp(argv[arg], "--partials") || !std::strcmp(argv[arg], "--tail")) && arg + 1 < argc) {
            const bool isPartials = !std::strcmp(argv[arg], "--partials");
            char *end = nullptr;
            const auto n = std::strtoul(argv[arg + 1], &end, 10);
            if (!*argv[arg + 1] || *end || n > (isPartials ? 32U : 30U) || (isPartials && !n))
                throw std::runtime_error("Expected partials 1..32 or tail seconds 0..30");
            (isPartials ? partials : tail) = static_cast<unsigned>(n);
            arg += 2;
        } else throw std::runtime_error("Unknown or incomplete option");
    }
    if (argc - arg != 0 && argc - arg != 4) throw std::runtime_error("Expected four paths or none");
    const char *controlPath = argc == arg ? "MT32CTRL.ROM" : argv[arg];
    const char *pcmPath = argc == arg ? "MT32PCM.ROM" : argv[arg + 1];
    const char *midiPath = argc == arg ? "SONG.MID" : argv[arg + 2];
    const char *outPath = argc == arg ? (digital ? "MT32.WAV" : "MT32.PCM") : argv[arg + 3];
    if (!std::strcmp(outPath, controlPath) || !std::strcmp(outPath, pcmPath) || !std::strcmp(outPath, midiPath))
        throw std::runtime_error("Output must differ from the input paths");
    // Refuse existing outputs, including aliases of the inputs on TOS.
    if (auto existing = std::fopen(outPath, "rb")) {
        std::fclose(existing);
        throw std::runtime_error("Output already exists; choose a new name or remove it first");
    }
    const auto song = f030mt32::readSMF(midiPath);
    Rom control(controlPath, ROMInfo::Control), pcm(pcmPath, ROMInfo::PCM);
    Reporter reporter;
    // Synth embeds its control-ROM image; do not put that on the TOS stack.
    auto synthStorage = std::make_unique<Synth>(&reporter);
    Synth &synth = *synthStorage;
    synth.selectRendererType(RendererType_BIT16S);
    synth.setNiceAmpRampEnabled(false);
    synth.setNicePanningEnabled(false);
    synth.setNicePartialMixingEnabled(false);
    synth.setMIDIDelayMode(MIDIDelayMode_DELAY_ALL);
    const auto name = control.image->getROMInfo()->shortName;
    const bool generation1 = !std::strncmp(name, "ctrl_mt32_1_", 12) || !std::strcmp(name, "ctrl_mt32_bluer");
    synth.setDACInputMode(digital ? DACInputMode_PURE : generation1 ? DACInputMode_GENERATION1 : DACInputMode_GENERATION2);
    if (!synth.open(*control.image, *pcm.image, partials, digital ? AnalogOutputMode_DIGITAL_ONLY : AnalogOutputMode_ACCURATE))
        throw std::runtime_error("Munt rejected the ROM pair");
    const double rate = digital ? 32000 : CODEC_RATE;
    SampleRateConverter converter(synth, rate, SamplerateConversionQuality_BEST);
    Output output(outPath, digital);
    const auto endFrame = static_cast<std::uint32_t>((song.endSample + tail * 32000ULL) * rate / 32000.0 + 0.5);
    if (!endFrame) throw std::runtime_error("MIDI duration and tail are both zero");
    std::printf("Rendering %u partials, %.2f seconds to %s (offline)\n", partials, endFrame / rate, outPath);
    const auto start = std::clock();
    std::size_t next = 0;
    std::uint32_t progress = 0;
    Bit16s buffer[512 * 2];
    while (output.frames < endFrame) {
        const auto horizon = synth.getInternalRenderedSampleCount() + 4096;
        while (next < song.events.size() && song.events[next].sample <= horizon) {
            const auto &event = song.events[next];
            bool accepted = true;
            if (!event.bytes.empty()) {
                if (event.bytes[0] == 0xf0) accepted = synth.playSysex(event.bytes.data(), event.bytes.size(), event.sample);
                else {
                    Bit32u msg = 0;
                    for (unsigned i = 0; i < event.bytes.size(); ++i) msg |= Bit32u(event.bytes[i]) << (8 * i);
                    accepted = synth.playMsg(msg, event.sample);
                }
            }
            if (!accepted) break; // render queued events, then retry; never drop MIDI
            ++next;
        }
        const unsigned count = std::min(512U, endFrame - output.frames);
        converter.getOutputSamples(buffer, count);
        output.write(buffer, count);
        if (output.frames >= progress) {
            std::printf("%lu / %lu frames\n", static_cast<unsigned long>(output.frames), static_cast<unsigned long>(endFrame));
            progress = output.frames + static_cast<std::uint32_t>(rate * 5);
        }
    }
    output.finish();
    std::printf("Done: %lu frames; CPU %.2f s for %.2f s audio\n", static_cast<unsigned long>(output.frames),
        double(std::clock() - start) / CLOCKS_PER_SEC, output.frames / rate);
    return 0;
}
}

int main(int argc, char **argv) {
    try { return render(argc, argv); }
    catch (const std::exception &e) {
        std::fprintf(stderr, "MT32REND: %s\nUsage: MT32REND [--digital] [--partials 1..32] [--tail 0..30]\n"
            "         [control.rom pcm.rom song.mid output]\n", e.what());
        return 1;
    }
}
