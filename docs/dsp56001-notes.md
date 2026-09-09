# DSP56001 implementation notes

The rules on this page are the ones the scaffold kernel already depends on, and
the traps that cost F030MXDRV real time. They are carried over deliberately:
the transport in `src/dsp/la32.asm` is the same code, so it inherits both the
constraints and the reasons.

`F030MXDRV/docs/DSP56001_um.pdf` is the architectural reference; section
numbers below refer to the Motorola DSP56000/DSP56001 User's Manual.

## Correctness rules, not optimizations

Violating any of these produces valid assembly with wrong chip state at
runtime. That is why they are on this page and not in a performance document.

**Address-generation pipeline.** Section 8.1, pipeline case 2: an indirect
address is formed before the preceding `MOVE` has finished writing its `Rn`.
One independent instruction cycle is required between writing `Rn` (or `Nn`)
and using it for an indirect access. Where there is no useful instruction to
put there, insert a `NOP` — the scaffold does exactly that in
`render_tone_period`, between `move b1,n1` and `move y:(r1+n1),y0`.

**Indexed addressing pairs same-numbered registers.** `(Rn+Nn)` and `(Rn)+Nn`
exist; `(R7+N5)` does not assemble. Address arithmetic also always applies the
pointer's own `Mn` modifier, so an indexed access through a modulo pointer must
keep base plus offset inside one modulo block.

**Modifier registers are shared state.** A subroutine that parks an `Mn` leaves
a time bomb for every later walker through that pointer. F030MXDRV lost
significant time to this: a helper restored `m3` to 63 during init, and a
later routine walking `r3` linearly silently wrapped its writes inside one
64-word block, corrupting scattered entries whose effect surfaced only as
intermittent discontinuities much later. Helpers must leave inherited modifiers
untouched and keep their own accesses wrap-free by placement instead.

**`DO` with a count of zero runs 65,536 times**, not zero (manual pages A-63
to A-65). Variable-count loops must branch around the `DO`. `REP` with a
register count of zero behaves the same way.

**`TST` sees the whole 56-bit accumulator.** A value computed by fractional
`MPY` must drop its A0/B0 fraction bits (`move b1,b`) before a zero guard, or
the guard tests bits that were never meant to be significant.

**Section 8.1.2 lists instructions forbidden near a loop end.** Keep `DO`
bodies to simple ALU and memory moves and let ASM56000 check them.

## Numeric representation

Section 4.2 defines data-ALU words as signed 24-bit fractional values with the
binary point left justified. The same bit patterns can be manipulated as small
integers with logical shifts and adds, which is what the scaffold's phase
accumulator does, but any use of `MPY`/`MAC`, scaling mode, rounding or
accumulator limiting must account for the fractional alignment explicitly.

This will matter more here than it did for the YM2151. The LA32 works in a log
domain of 16-bit fixed-point values with a 12-bit fractional part
(`LA32WaveGenerator.h`), and the reverb is a MAC-based delay network. Two
different fixed-point conventions in one kernel is a documented decision, not
something to leave implicit.

## Falcon memory decode

Hatari's Falcon decode, and the hardware it models, maps external P to the 32K
SRAM directly, external Y onto the same lower 16K word for word, and external X
onto the upper 16K at `phys = addr + $4000`.

The scaffold's layout stays clear of the overlap by placing both period buffers
in external X at `$1000` and `$1400` (physical `$5000` and `$5400`), well above
anything the small program touches. A larger kernel will not have that luxury:
F030MXDRV ended up placing program code *into the gaps between live data
arrays* and depends on the decode being exactly as described. That is a silent
corruption if the hardware differs by one region, which is why F030MXDRV built
a standalone bus probe to confirm it — write a pattern through `Y:$2000`, read
it back through `P:$2000` and `X:$6000`. **This project should port that probe
before it trusts any hardware audio result.**

Hatari charges no wait states for external memory and ignores the bus control
register, so it cannot answer that question either way.

## Boot-time register state

`Dsp_ExecBoot` bypasses the TOS loader, so nothing has cleaned up after reset.
The scaffold's `start:` therefore does four things that are all load-bearing:

- `movep #1,x:m_pbc` — enable the Falcon host port.
- `movep #$1f8,x:m_pcc` — put Port C pins into SSI function. They reset to
  GPIO, which leaves the slave SSI clockless on real hardware while working
  fine under an emulator. This was a real hardware failure in F030MXDRV.
- `movep #0,x:m_bcr` — reset leaves fifteen wait states on every external
  access. Hatari ignores the register entirely, so a kernel that omits this
  is only slow on the machine that matters.
- `movep #$3000,x:m_ipr` and `andi #$fc,mr` — SSI interrupt at level 2, and
  lower the status-register mask, which reset leaves at I1:I0=11 masking that
  level.

## Initialized data can only be shipped in P

The stage-two loader transports P-memory sections and there is no X or Y record
type. Anything that must start with a value either lives in P and is copied at
boot — which is what the scaffold's tone table does — or is uploaded at runtime
over the protocol, which is how F030MXDRV delivers its ymfm tables. Everything
else uses `ds`, which reserves without emitting.

For this project that is a design input, not a nuisance: `exp9` and `logsin9`
are 512 entries each and the reverb needs none, so P-resident tables copied at
boot are affordable. The 262,144-sample PCM ROM is not, by any route; see
[`architecture.md`](architecture.md#the-pcm-rom-problem).

## The host-port write hazard

TOS 4.02's `Dsp_BlkUnpacked` polls host-port TXDE only before its first word,
then writes the rest of the block blind. Any DSP receive loop that starts more
than about one host-write period after the command word silently loses a word
to the one-deep transmit latch — after which the DSP waits for a word that
never arrives and the host waits for a reply that never comes.

Two things follow, and the scaffold does both:

- every multi-word upload is gated on a ready token the DSP sends from
  immediately before its parked receive loop (`$524459`, `RDY`); and
- the host paces each word on TXDE itself rather than trusting the XBIOS call
  (`dsp_blast_paced` in `src/m68k/dsp_link.s`).

Hatari's DSP has no host-port wait states, so this failure only ever appears on
real hardware.

## Embedded second-stage program loader

`Dsp_ExecBoot` installs at most 512 words in internal P RAM, and TOS's
converted-LOD path has an 8 KiB ceiling that an LA32 kernel will not fit under.
So the executable embeds a small first-stage loader plus the complete sparse
program image, and `tools/generate_dsp_stage2.py` builds both.

The generator refuses, at build time: a bootstrap above the 512-word limit, any
overlap with the reserved `P:$0040-$007f` loader gap, non-P sections, sections
outside 16-bit P memory, and overlapping sections. That last check is the one
that matters day to day — the assembler will happily let a section grow past
the next hardcoded `org`, and the loader would then silently clobber the later
section's words. In the scaffold it is what stops the kernel growing into its
own tone table at `P:$0400`.
