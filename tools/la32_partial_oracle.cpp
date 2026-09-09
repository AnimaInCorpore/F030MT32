// LA32 synth-partial and Boss reverb oracle for the F030MT32 profile spikes.
//
// Drives Munt's bit-accurate integer LA32 model (LA32IntPartialPair) with a
// constant amp, pitch and cutoff - exactly what the DSP kernel holds across a
// block - and prints one line per frame: the 16-bit partial output and its
// left/right pan-mixed contribution, computed the way Partial::produceAndMix
// does. `--dump-tables` prints the exp9/logsin9/decay tables the same code
// uses, so tools/la32_partial.py derives the DSP tables from identical data.
// `reverb TIME LEVEL` reads such frames from standard input and runs their
// left/right pair through Munt's BReverbModel in its MT-32 room mode,
// printing the wet output in the same three-column shape.
//
// Build-time reference only; nothing from here runs on the Falcon.

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include "BReverbModel.h"
#include "Enumerations.h"
#include "LA32WaveGenerator.h"
#include "Tables.h"

using namespace MT32Emu;

static void usage() {
	fprintf(stderr,
		"usage: la32_partial_oracle --dump-tables\n"
		"       la32_partial_oracle render SAW PULSEWIDTH RESONANCE AMP PITCH CUTOFF FRAMES PANL PANR\n"
		"       la32_partial_oracle reverb TIME LEVEL < frames\n");
	exit(2);
}

static int runReverb(unsigned time, unsigned level) {
	BReverbModel *model = BReverbModel::createBReverbModel(REVERB_MODE_ROOM, true, RendererType_BIT16S);
	if (model == NULL) return 1;
	model->open();
	model->setParameters(Bit8u(time), Bit8u(level));
	int sample, left, right;
	while (scanf("%d %d %d", &sample, &left, &right) == 3) {
		const IntSample inLeft = IntSample(left);
		const IntSample inRight = IntSample(right);
		IntSample outLeft = 0, outRight = 0;
		model->process(&inLeft, &inRight, &outLeft, &outRight, 1);
		printf("%d %d %d\n", sample, int(outLeft), int(outRight));
	}
	delete model;
	return 0;
}

int main(int argc, char **argv) {
	const Tables &tables = Tables::getInstance();
	if (argc == 4 && strcmp(argv[1], "reverb") == 0) {
		const unsigned time = strtoul(argv[2], NULL, 0);
		const unsigned level = strtoul(argv[3], NULL, 0);
		if (time > 7 || level > 7) usage();
		return runReverb(time, level);
	}
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
