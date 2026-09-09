// LA32 synth-partial oracle for the F030MT32 profile spike.
//
// Drives Munt's bit-accurate integer LA32 model (LA32IntPartialPair) with a
// constant amp, pitch and cutoff - exactly what the DSP kernel holds across a
// block - and prints one line per frame: the 16-bit partial output and its
// left/right pan-mixed contribution, computed the way Partial::produceAndMix
// does. `--dump-tables` prints the exp9/logsin9/decay tables the same code
// uses, so tools/la32_partial.py derives the DSP tables from identical data.
//
// Build-time reference only; nothing from here runs on the Falcon.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "LA32WaveGenerator.h"
#include "Tables.h"

using namespace MT32Emu;

static void usage() {
	fprintf(stderr,
		"usage: la32_partial_oracle --dump-tables\n"
		"       la32_partial_oracle render SAW PULSEWIDTH RESONANCE AMP PITCH CUTOFF FRAMES PANL PANR\n");
	exit(2);
}

int main(int argc, char **argv) {
	const Tables &tables = Tables::getInstance();
	if (argc == 2 && strcmp(argv[1], "--dump-tables") == 0) {
		printf("exp9");
		for (int i = 0; i < 512; i++) printf(" %u", unsigned(tables.exp9[i]));
		printf("\nlogsin9");
		for (int i = 0; i < 512; i++) printf(" %u", unsigned(tables.logsin9[i]));
		printf("\nresAmpDecayFactors");
		for (int i = 0; i < 8; i++) printf(" %u", unsigned(tables.resAmpDecayFactors[i]));
		printf("\n");
		return 0;
	}
	if (argc != 11 || strcmp(argv[1], "render") != 0) usage();

	const bool sawtooth = atoi(argv[2]) != 0;
	const unsigned pulseWidth = strtoul(argv[3], NULL, 0);
	const unsigned resonance = strtoul(argv[4], NULL, 0);
	const Bit32u amp = Bit32u(strtoul(argv[5], NULL, 0));
	const Bit16u pitch = Bit16u(strtoul(argv[6], NULL, 0));
	const Bit32u cutoff = Bit32u(strtoul(argv[7], NULL, 0));
	const unsigned frames = strtoul(argv[8], NULL, 0);
	const int panLeft = atoi(argv[9]);
	const int panRight = atoi(argv[10]);
	if (pulseWidth > 255 || resonance < 1 || resonance > 31 || pitch > 59392) usage();

	LA32IntPartialPair::initTables(tables);
	LA32IntPartialPair pair;
	pair.init(false, false);
	pair.initSynth(LA32PartialPair::MASTER, sawtooth, Bit8u(pulseWidth), Bit8u(resonance));
	pair.deactivate(LA32PartialPair::SLAVE);

	for (unsigned i = 0; i < frames; i++) {
		pair.generateNextSample(LA32PartialPair::MASTER, amp, pitch, cutoff);
		const Bit16s sample = pair.nextOutSample();
		// Partial::produceAndMixSample: (sample * pan) >> 13, arithmetic shift.
		const int left = (int(sample) * panLeft) >> 13;
		const int right = (int(sample) * panRight) >> 13;
		printf("%d %d %d\n", int(sample), left, right);
	}
	return 0;
}
