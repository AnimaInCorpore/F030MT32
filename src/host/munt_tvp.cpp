// Adapter to Munt's LGPL-2.1-or-later TVP implementation (included below).
// Munt uses rand() & 3 for its nondeterministic MCU pitch-timer jitter.
// Use the same seeded sequence on TOS and the workstation so regression
// renders compare the synthesis, not two C libraries' different rand().
#include <cstdint>
#include <cstdlib>

namespace MT32Emu {
static int rand() {
    static std::uint32_t state = 1;
    state = state * 214013U + 2531011U;
    return int((state >> 16) & 0x7fff);
}
}

#include "../../third_party/munt/mt32emu/src/TVP.cpp"
