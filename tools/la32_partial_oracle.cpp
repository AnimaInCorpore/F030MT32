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
// printing the wet output in the same three-column shape. `pcm` reads a
// wave in the PCM ROM's word format from standard input and renders one
// PCM partial from it, the model the 68030 spike reproduces. `control`
// drives a synth partial with amp, pitch and cutoff that move the way the
// MT-32's own control path moves them - LA32Ramp for amp and cutoff, a
// triangle vibrato at the MCU timer's period for pitch - either per sample
// or held per block, so the block-rate design can be graded against the
// per-sample model.
//
// Build-time reference only; nothing from here runs on the Falcon.

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "BReverbModel.h"
#include "Enumerations.h"
#include "LA32Ramp.h"
#include "LA32WaveGenerator.h"
#include "Tables.h"

using namespace MT32Emu;

static void usage() {
	fprintf(stderr,
		"usage: la32_partial_oracle --dump-tables\n"
		"       la32_partial_oracle render SAW PULSEWIDTH RESONANCE AMP PITCH CUTOFF FRAMES PANL PANR\n"
		"       la32_partial_oracle reverb TIME LEVEL < frames\n"
		"       la32_partial_oracle pcm LENGTH LOOPED AMP PITCH FRAMES PANL PANR < wave\n"
		"       la32_partial_oracle control SAW PULSEWIDTH RESONANCE PANL PANR FRAMES BLOCK MODE\n"
		"                           BASEPITCH BASECUTOFF LFODEPTH LFOPERIOD < segments\n"
		"         segments: lines 'a TARGET INCREMENT' and 'c TARGET INCREMENT', each ramp\n"
		"         starting when the previous one of its kind raises its interrupt;\n"
		"         MODE letters: A/P/C hold amp/pitch/cutoff per block, R ramps the amp\n"
		"         linearly across the block, S holds the schedule given by lines\n"
		"         'h FRAME AMPT PITCH CUTOFF3', D dumps the per-sample controls instead\n");
	exit(2);
}

struct Segment {
	Bit8u target;
	Bit8u increment;
};

// Munt's TVP re-evaluates the pitch every SAMPLE_RATE / 4000 samples plus a
// random 0..3, the MT-32's MCU timer; this probe keeps the nominal period
// and drops the jitter so a run is reproducible.
static const unsigned PITCH_TIMER_SAMPLES = 8;

static int runControl(const Tables &tables, bool sawtooth, unsigned pulseWidth, unsigned resonance,
		int panLeft, int panRight, unsigned frames, unsigned block, const char *mode,
		unsigned basePitch, unsigned baseCutoff, int lfoDepth, unsigned lfoPeriod) {
	std::vector<Segment> ampSegments, cutoffSegments;
	// A schedule of held controls, the records a host sends only when a
	// control moved: from each frame on, amp >> 10, pitch and cutoff >> 3.
	struct Held {
		unsigned start;
		Bit32u ampt;
		Bit16u pitch;
		Bit32u cutoff3;
	};
	std::vector<Held> schedule;
	char kind[8];
	while (scanf("%7s", kind) == 1) {
		if (kind[0] == 'a' || kind[0] == 'c') {
			int target, increment;
			if (scanf("%d %d", &target, &increment) != 2) usage();
			const Segment segment = { Bit8u(target), Bit8u(increment) };
			(kind[0] == 'a' ? ampSegments : cutoffSegments).push_back(segment);
		} else if (kind[0] == 'h') {
			unsigned start, ampt, pitchWord, cutoff3;
			if (scanf("%u %u %u %u", &start, &ampt, &pitchWord, &cutoff3) != 4) usage();
			const Held held = { start, ampt, Bit16u(pitchWord), cutoff3 };
			schedule.push_back(held);
		} else {
			usage();
		}
	}
	if (block == 0) usage();

	// Pass one: the per-sample controls, with one block of lookahead for the
	// ramped-amp mode. The ramps behave exactly as Partial::getAmpValue and
	// getCutoffValue drive them: the value is read, then a raised interrupt
	// starts the next segment for the following sample.
	LA32Ramp::initTables(tables);
	LA32Ramp ampRamp, cutoffRamp;
	size_t ampIndex = 0, cutoffIndex = 0;
	if (!ampSegments.empty()) ampRamp.startRamp(ampSegments[0].target, ampSegments[0].increment);
	if (!cutoffSegments.empty()) cutoffRamp.startRamp(cutoffSegments[0].target, cutoffSegments[0].increment);
	const unsigned total = frames + block;
	std::vector<Bit32u> amp(total), cutoff(total);
	std::vector<Bit16u> pitch(total);
	for (unsigned i = 0; i < total; i++) {
		amp[i] = 67117056 - ampRamp.nextValue();
		if (ampRamp.checkInterrupt() && ++ampIndex < ampSegments.size()) {
			ampRamp.startRamp(ampSegments[ampIndex].target, ampSegments[ampIndex].increment);
		}
		cutoff[i] = (baseCutoff << 18) + cutoffRamp.nextValue();
		if (cutoffRamp.checkInterrupt() && ++cutoffIndex < cutoffSegments.size()) {
			cutoffRamp.startRamp(cutoffSegments[cutoffIndex].target, cutoffSegments[cutoffIndex].increment);
		}
		int lfo = 0;
		if (lfoDepth != 0 && lfoPeriod != 0) {
			const unsigned t = i - i % PITCH_TIMER_SAMPLES;
			const double x = 4.0 * double(t % lfoPeriod) / double(lfoPeriod);
			const double triangle = x < 1.0 ? x : (x < 3.0 ? 2.0 - x : x - 4.0);
			lfo = int(lround(triangle * lfoDepth));
		}
		pitch[i] = Bit16u(int(basePitch) + lfo);
	}

	const bool holdAmp = strchr(mode, 'A') != NULL;
	const bool holdPitch = strchr(mode, 'P') != NULL;
	const bool holdCutoff = strchr(mode, 'C') != NULL;
	const bool rampAmp = strchr(mode, 'R') != NULL;
	const bool scheduled = strchr(mode, 'S') != NULL;
	if (scheduled && (schedule.empty() || schedule[0].start != 0)) usage();
	if (strchr(mode, 'D') != NULL) {
		// The words the host would send per block: amp >> 10, pitch, cutoff >> 3,
		// the cutoff clamped as generateNextSample clamps it, which also keeps
		// the word inside the DSP's signed 24 bits when the base and the
		// modifier add up past 256 levels.
		const Bit32u maxCutoff = 240 << 18;
		for (unsigned i = 0; i < frames; i++) {
			const Bit32u c = cutoff[i] < maxCutoff ? cutoff[i] : maxCutoff;
			printf("%u %u %u\n", unsigned(amp[i] >> 10), unsigned(pitch[i]), unsigned(c >> 3));
		}
		return 0;
	}

	// Pass two: render with the controls the block-rate design applies.
	LA32IntPartialPair::initTables(tables);
	LA32IntPartialPair pair;
	pair.init(false, false);
	pair.initSynth(LA32PartialPair::MASTER, sawtooth, Bit8u(pulseWidth), Bit8u(resonance));
	pair.deactivate(LA32PartialPair::SLAVE);
	size_t held = 0;
	for (unsigned i = 0; i < frames; i++) {
		const unsigned start = i - i % block;
		Bit32u a = amp[i];
		Bit16u p = pitch[i];
		Bit32u c = cutoff[i];
		if (scheduled) {
			while (held + 1 < schedule.size() && schedule[held + 1].start <= i) held++;
			a = schedule[held].ampt << 10;
			p = schedule[held].pitch;
			c = schedule[held].cutoff3 << 3;
		} else if (block > 1) {
			if (holdPitch) p = pitch[start];
			if (holdCutoff) c = (cutoff[start] >> 3) << 3;
			if (rampAmp) {
				// One add per frame on the DSP: the slope between this block's
				// and the next block's amp term, truncated toward zero.
				const Bit32s from = Bit32s(amp[start] >> 10);
				const Bit32s to = Bit32s(amp[start + block] >> 10);
				const Bit32s slope = (to - from) / Bit32s(block);
				a = Bit32u(from + slope * Bit32s(i - start)) << 10;
			} else if (holdAmp) {
				a = (amp[start] >> 10) << 10;
			}
		}
		pair.generateNextSample(LA32PartialPair::MASTER, a, p, c);
		const Bit16s sample = pair.nextOutSample();
		const int left = (int(sample) * panLeft) >> 13;
		const int right = (int(sample) * panRight) >> 13;
		printf("%d %d %d\n", int(sample), left, right);
	}
	return 0;
}

// One PCM partial, the master of a pair with the slave silent, so the wave
// is interpolated the way every PCM partial outside a ring-modulated
// structure is. The wave arrives as the 16-bit words Synth::loadPCMROM
// leaves in pcmROMData, one per line.
static int runPCM(const Tables &tables, unsigned length, bool looped, Bit32u amp, Bit16u pitch,
		unsigned frames, int panLeft, int panRight) {
	std::vector<Bit16s> wave(length);
	for (unsigned i = 0; i < length; i++) {
		int word;
		if (scanf("%d", &word) != 1) {
			fprintf(stderr, "la32_partial_oracle: the wave has fewer than %u words\n", length);
			return 1;
		}
		wave[i] = Bit16s(word);
	}
	LA32IntPartialPair::initTables(tables);
	LA32IntPartialPair pair;
	pair.init(false, false);
	pair.initPCM(LA32PartialPair::MASTER, wave.data(), length, looped);
	pair.deactivate(LA32PartialPair::SLAVE);
	for (unsigned i = 0; i < frames; i++) {
		pair.generateNextSample(LA32PartialPair::MASTER, amp, pitch, 0);
		const Bit16s sample = pair.nextOutSample();
		const int left = (int(sample) * panLeft) >> 13;
		const int right = (int(sample) * panRight) >> 13;
		printf("%d %d %d\n", int(sample), left, right);
	}
	return 0;
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
	if (argc == 14 && strcmp(argv[1], "control") == 0) {
		const bool sawtooth = atoi(argv[2]) != 0;
		const unsigned pulseWidth = strtoul(argv[3], NULL, 0);
		const unsigned resonance = strtoul(argv[4], NULL, 0);
		const int panLeft = atoi(argv[5]);
		const int panRight = atoi(argv[6]);
		const unsigned frames = strtoul(argv[7], NULL, 0);
		const unsigned block = strtoul(argv[8], NULL, 0);
		const unsigned basePitch = strtoul(argv[10], NULL, 0);
		const unsigned baseCutoff = strtoul(argv[11], NULL, 0);
		const int lfoDepth = atoi(argv[12]);
		const unsigned lfoPeriod = strtoul(argv[13], NULL, 0);
		if (pulseWidth > 255 || resonance < 1 || resonance > 31 || basePitch > 59392 || baseCutoff > 255) usage();
		return runControl(tables, sawtooth, pulseWidth, resonance, panLeft, panRight, frames, block,
			argv[9], basePitch, baseCutoff, lfoDepth, lfoPeriod);
	}
	if (argc == 9 && strcmp(argv[1], "pcm") == 0) {
		const unsigned length = strtoul(argv[2], NULL, 0);
		const bool looped = atoi(argv[3]) != 0;
		const Bit32u amp = Bit32u(strtoul(argv[4], NULL, 0));
		const Bit16u pitch = Bit16u(strtoul(argv[5], NULL, 0));
		const unsigned frames = strtoul(argv[6], NULL, 0);
		const int panLeft = atoi(argv[7]);
		const int panRight = atoi(argv[8]);
		if (length == 0 || length > 262144 || pitch > 59392) usage();
		return runPCM(tables, length, looped, amp, pitch, frames, panLeft, panRight);
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
