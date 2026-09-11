#include "../src/host/smf.h"
#include <cstdio>
#include <exception>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    try {
        const auto song = f030mt32::readSMF(argv[1]);
        for (const auto &e : song.events) {
            if (e.bytes.empty()) continue;
            std::printf("%lu", static_cast<unsigned long>(e.sample));
            for (auto b : e.bytes) std::printf(" %02x", unsigned(b));
            std::puts("");
        }
        std::printf("end %lu\n", static_cast<unsigned long>(song.endSample));
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s\n", e.what());
        return 1;
    }
}
