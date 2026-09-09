# Which Hatari the gates run, and why it matters

Every emulator gate in this repository is meant to run the DSP-calibrated
Hatari built in the F030Arcade tree, not a stock release. The two builds agree
instruction for instruction; they disagree about how much time the Falcon's
DSP56001 has, and a project whose whole feasibility question is "does this fit
in 489 cycles per frame" cannot afford that disagreement.

This is inherited knowledge, not a finding of this project.
`F030MXDRV/docs/hatari-timing.md` carries the full record, including the
measurements against DSPBench v3.0b in `F030Arcade/hatari.md` and the 351 late
periods the stock build originally hid.

## Selecting the binary

`HATARI` resolves, in order, to an explicit override, the calibrated build
under `F030ARCADE`, and finally `hatari` on `PATH`:

```sh
make smoke                                    # calibrated build if present
make smoke HATARI=/path/to/hatari             # explicit override
make smoke F030ARCADE=/path/to/F030Arcade     # relocated tree
```

Running on any other binary is allowed and prints a warning rather than
failing, because every static gate still works and a stock build is fine for
checking that the transport is wired up correctly. It is not fine for any
timing result. A silent fallback is exactly how the F030MXDRV result went
unnoticed for as long as it did.

## What the calibrated build fixes

Two independent errors, both documented and verified in `F030Arcade/hatari.md`:

- **DSP clock.** Every caller already scaled CPU cycles by
  `DSP_CPU_FREQ_RATIO` before calling `DSP_Run()`, and `DSP_Run()` applied the
  ratio a second time. Stock Hatari therefore runs the DSP at 32 MIPS instead
  of the Falcon's 16. The per-instruction cycle model was already exact,
  external-memory penalty included; only the rate at which cycles were handed
  out was wrong.
- **Host port.** Upstream charges zero wait states for the first byte of a
  CPU-side host-port access and four for each later byte, which DSPBench
  measures at 72–174 % of hardware. The calibrated build replaces that with a
  per-direction, per-size table charged once per access, bringing the eleven
  host tests from 28.3 pp RMS error to 10.4 pp.

## What this means for this project

Two practical consequences, both relevant before any synthesis exists.

**Bracketed cycle profiles are unaffected.** The per-instruction cost model is
the same in both builds, so a profile that brackets a stretch of DSP code
between host-port markers reports the same number either way. Every
measurement listed in [`la32-budget.md`](la32-budget.md) is of that kind, which
is convenient: the numbers that decide whether the project is possible can be
taken before anyone gets the emulator right.

**Anything paced by real time is affected.** Period handoffs, underruns, host
stalls and occupancy all depend on the rate at which the DSP is given cycles.
The scaffold's `make smoke` gate only checks that the sequence happened, not
that it happened on time, so it passes on either build — but the moment a gate
starts asserting cadence, it means nothing on a stock build.

## What none of it says

Hatari's own documentation states that its DSP emulation is instruction-wise
correct and not cycle accurate, particularly for 68030-to-DSP synchronization.
It also charges no wait states for Falcon external memory and ignores the bus
control register entirely. Both matter for a kernel that will be
external-memory dense.

So the emulator can establish relative cost and can catch a structural mistake.
It cannot settle underrun behaviour, and it cannot settle what the real
wait-state configuration costs. Those stay hardware questions.
F030MXDRV answered them with two standalone probe programs — an SSI rate test
and a DSP bus probe — and this project will need the equivalents before it
trusts any hardware result.
