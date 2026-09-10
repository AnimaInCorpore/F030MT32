; F030MT32 DSP scaffold kernel
;
; This is the transport half of the port, not the synthesizer. It boots, talks
; the v1 host protocol, and drives the Falcon codec from two 512-frame stereo
; period buffers with a boundary-safe handoff. Two sources are provided so the
; audio path can be validated before any LA32 code exists:
;
;   MT32_CMD_START_TONE    the DSP generates its own sine, no host data path
;   MT32_CMD_START_STREAM  the 68030 supplies every period
;
; The boot sequence, the SSI configuration, the fast transmit interrupt, the
; modulo output pointer and the handoff are taken unchanged from the measured
; F030MXDRV production path; only the synthesis they wrap is different. See
; docs/architecture.md for what replaces the tone generator, and
; docs/dsp56001-notes.md for the DSP56001 rules this file already obeys.
;
; The first LA32 code lives here as well. MT32_CMD_PROFILE_PARTIAL renders
; one synth partial with amp, pitch and cutoff held constant, as a block-rate
; kernel would hold them, into X:$1000 for the Hatari cycle profiler and the
; oracle comparison in tools/la32_partial.py. Two kernels share the machinery:
; the exact one reproduces Munt's integer LA32WaveGenerator bit for bit, the
; perceptual one keeps its positions and log sums but leaves the log domain
; through single-table lookups. The four render loops sit in internal P so
; their fetches never contend with the external table reads; the transport
; moved to external P:$0200 to make room, and its scalar state moved to
; internal Y because internal X now holds the first page of the exact
; kernel's unlog table.
;
; Assembled with LA32_REVERB_IMAGE defined (src/dsp/reverb.asm), the same
; source becomes the reverb profile image: the partial loops and tables give
; way to the Boss reverb loop, its delay lines, and the input frames it
; processes in place. See docs/la32-budget.md for the measurements.

        include 'ioequ.inc'
        include 'protocol.inc'

; LA32 spike memory map. tools/la32_partial.py is the source of every table
; address: it emits the tables as P sections at the alias of each X/Y home
; (Falcon external P = phys, external Y = phys, external X = phys - $4000),
; so the stage-two loader delivers X and Y data it was never taught about,
; and hands the kernel the bases it needs through the constant and
; configuration images. Only the unlog table's first 256 words, which live
; in internal X, are copied at boot.
LA32_UNLOG_X        equ     $0000
LA32_UNLOG_IMAGE_P  equ     $4000
LA32_UNLOG_COPY     equ     256
LA32_CONST_WORDS    equ     21
LA32_CONFIG_WORDS   equ     18
LA32_OUTPUT_BASE    equ     $1000
LA32_OUTPUT_WORDS   equ     2*LA32_PROFILE_FRAMES

; Boss reverb, MT-32 room mode: delay-line homes in Y (mirrored by the
; Python tool, which checks each base is aligned to the power of two above
; the line's length, as modulo addressing requires) and the fixed tap
; distances behind each comb's write position.
RV_ENT_BASE         equ     $0c00
RV_ENT_SIZE         equ     576
RV_AP0_BASE         equ     $3800
RV_AP0_SIZE         equ     994
RV_AP1_BASE         equ     $3c00
RV_AP1_SIZE         equ     729
RV_AP2_BASE         equ     $0f00
RV_AP2_SIZE         equ     78
RV_COMB1_BASE       equ     $3000
RV_COMB1_SIZE       equ     2040
RV_COMB2_BASE       equ     $2000
RV_COMB2_SIZE       equ     2752
RV_COMB3_BASE       equ     $1000
RV_COMB3_SIZE       equ     3629
RV_TAP_R1           equ     -1019
RV_TAP_L3           equ     -1814

; -----------------------------------------------------------------------------
; Bootstrap and interrupt vectors
; -----------------------------------------------------------------------------

        org     p:$0
        jmp     start

; Buffered SSI owns r6/m6 while active. The normal fast interrupt transfers
; one prepared word without disturbing any synthesis state. The exception
; vector enters a recovery ISR because clearing TUE requires reading SSISR and
; then writing TX; the normal path stays a two-instruction fast interrupt.
        org     p:$10
        movep   x:(r6)+,x:m_tx
        nop

        org     p:$12
        jsr     ssi_tx_exception

; -----------------------------------------------------------------------------
; Scalar state in internal Y (internal X is the unlog table's first page)
; -----------------------------------------------------------------------------

        org     y:$0

last_command:
        ds      1
source_mode:
        ds      1                       ; 0 idle, 1 tone, 2 host stream
ssi_frame_count:
        ds      1                       ; codec frames emitted, modulo 2^24
ssi_period_count:
        ds      1                       ; completed period handoffs
ssi_active_base:
        ds      1                       ; buffer the SSI is playing
ssi_refill_base:
        ds      1                       ; buffer being prepared
ssi_status_snapshot:
        ds      1                       ; SSISR at the last underrun
tone_phase:
        ds      1                       ; 16-bit accumulator
tone_step:
        ds      1                       ; 16-bit phase increment per frame

        IF      @DEF(LA32_REVERB_IMAGE)

; Reverb image: the run's constants, copied from the configuration image by
; command_profile, and two scratch words. Word 8 is the kernel selector the
; partial image also reads, so both images share one image layout.
        org     y:$10
rv_input        ds      1               ; the partial run whose frames are the input
rv_fb1          ds      1               ; comb feedback factors << 15
rv_fb2          ds      1
rv_fb3          ds      1
rv_dry          ds      1               ; dry amp << 15
rv_wet          ds      1               ; wet level << 15
rv_ffent        ds      1               ; entrance low-pass factor << 15
rv_lpf          ds      1               ; entrance output amp << 15
rv_kernel       ds      1               ; 2
rv_ffc          ds      1               ; comb filter factor << 15
rv_n5l          ds      1               ; comb 2 left tap offset
rv_n5r          ds      1               ; comb 2 right tap offset
rv_max          ds      1               ; 32767
rv_min          ds      1               ; -32768
rv_quarter      ds      1               ; 2^21: mpy by it is a right shift by 2
rv_half         ds      1               ; 2^22: mpy by it is a right shift by 1
rv_pad          ds      2
rv_outl1        ds      1               ; scratch: comb 1's oldest word
rv_outr3        ds      1               ; scratch: comb 3's last word

        ELSE

; LA32 partial state, fixed constants and the active run's configuration, all
; within the 6-bit short-absolute range so the loops load them for free
; beside ALU work. la32_tables_install copies the fixed words from P at boot;
; command_profile copies a configuration block over la_step3 onwards. The
; layout is mirrored by tools/la32_partial.py.
; Block-derivation scratch and the amp ramp's words, short-addressable
; beside the transport state: the kernels read la_aslope, la_f and la_r in
; parallel moves every frame.
        org     y:$9
la_scr_ampt     ds      1               ; the record's amp >> 10
la_aslope       ds      1               ; the record's amp slope per frame, log units
la_f            ds      1               ; perceptual amp ramp: the sum's factor, Q23
la_scr_hl4      ds      1               ; high linear length >> 4
la_scr_ll4      ds      1               ; low linear length >> 4
la_r            ds      1               ; perceptual amp ramp: F's factor per frame, Q22
la_cut_res      ds      1               ; ras + the cutoff's resonance term - 4096

        org     y:$10
la_wp3          ds      1               ; wave position << 3, advanced per frame
la_wphmask      ds      1               ; $7ff800 - first fixed word
la_sh5          ds      1               ; 2^18: mpy by it is a right shift by 5
la_m511         ds      1
la_m7fe0        ds      1               ; R4 bits 5-14: the exact resonance index
la_sh12         ds      1               ; 2^11: mpy by it is a right shift by 12
la_m4095        ds      1
la_2p14         ds      1
la_pos21        ds      1               ; 2^21: sawtooth cosine offset, wp3 units
la_2p22         ds      1
la_mcos         ds      1               ; $3ff800: exact cosine index bits
la_rec1         ds      1               ; address of la_half1
la_sh7          ds      1               ; 2^7
la_sgnbit       ds      1               ; $800000
la_shtab        ds      1               ; exact power table entry for integer part 0
la_rtab         ds      1               ; exact resonance log sine table
la_mffe0        ds      1               ; R4 bits 5-15: the perceptual signed index
la_sh4          ds      1               ; 2^19: mpy by it is a right shift by 4
la_m65535       ds      1
la_gtab         ds      1               ; perceptual gain table entry for a zero argument
la_ctab         ds      1               ; perceptual signed cosine table
la_mcos11       ds      1               ; $7ff000: perceptual cosine index bits - last fixed word
la_sqlog        ds      1               ; scratch: square log sample
la_rmul         ds      1               ; scratch: resonance sign multiplier
la_rlog         ds      1               ; scratch
la_frames       ds      1               ; frames per kernel call: a run or a block
la_blocks       ds      1               ; blocks in a control run
la_step3        ds      1               ; configuration: sampleStep << 3
la_k7           ds      1               ; (resonanceWaveLengthFactor >> 4) << 7
la_b3           ds      1               ; start of the negative half, S4 units
la_ampt         ds      1               ; amp>>10 plus the low-cutoff square term
la_rbase        ds      1               ; amp>>10 + resonance amp subtraction + cutoff term - 4096
la_panl         ds      1               ; pan factors, << 9 exact, << 10 perceptual
la_panr         ds      1
la_saw          ds      1               ; nonzero selects a sawtooth loop
la_kernel       ds      1               ; 0 exact, 1 perceptual
la_sqbase       ds      1               ; the kernel's FWD square table; ZERO and REV follow
la_half0        ds      4               ; per half, exact: sign base, linear length,
la_half1        ds      4               ;   decay << 15, square sign multiplier;
                                        ; perceptual: linear length, sine table base,
                                        ;   decay << 15, signed square gain
la_entry        ds      1               ; control run: the kernel entry
la_rest         ds      1               ; control run: block length - 1
la_poschg       ds      1               ; control run: the position constants changed

; Control-run state, past the short-absolute range: the per-block derivation
; is the only reader and can afford long addressing.
        org     y:$40
la_epw          ds      1               ; effective pulse width term, static per partial
la_ras          ds      1               ; resonance amp subtraction, static per partial
la_record       ds      1               ; next control record
la_recbase      ds      1               ; the first control record
la_blocklen     ds      1               ; frames per block
; Munt applies a sample's pitch and cutoff to the wave position one sample
; after its amp - advancePosition runs after the log samples - so a block's
; position constants wait here through its first frame.
la_pend_step3   ds      1
la_pend_k7      ds      1
la_pend_b3      ds      1
la_prev_pitch   ds      1               ; the previous block's pitch, or -1
la_prev_c       ds      1               ; the previous block's cutoff >> 3, or -1
la_scr_ecv      ds      1               ; effective cutoff value
la_scr_rwlf4    ds      1               ; resonance wave length factor << 4
la_cut_amp      ds      1               ; the cutoff's square amp term, 0 above the middle
la_pow_guard    ds      9               ; zeros: a shift that clears the value
la_pow          ds      24              ; 2^0 .. 2^22, then a zero for a shift of none

; A control run's payload lands here from the host port: the header in a
; gap between the Y tables, the records - five words each, the frames a
; record holds for, then its amp >> 10, the amp's slope per frame, pitch
; and cutoff >> 3 - in the free X memory past the exact power table.
LA32_CONTROL_HEADER_Y equ $1e00
LA32_CONTROL_RECORDS equ $3900

; The perceptual amp ramp's factor per frame, Q22, from the image
; tools/la32_partial.py emits below the X table alias: 2^(s/4096) for a
; rising amp at slope -s, then 2^(-s/4096) for a falling one, s below
; LA32_RAMP_STEEP; steeper slopes come from the exponent table.
LA32_RAMP_RISING    equ     $3c00
LA32_RAMP_FALLING   equ     $3e00
LA32_RAMP_STEEP     equ     512

        ENDIF

; The 256-entry test-tone table is external Y data now, delivered by the P
; alias like the LA32 tables, so the boot no longer copies it.
        org     y:$800
tone_sine:
        ds      TONE_TABLE_WORDS

; Two interleaved stereo periods in external X. Both bases are 1024-word
; aligned because the SSI output pointer runs modulo MT32_PERIOD_MODULO, and
; ds keeps them out of the loader image. External X decodes at phys+$4000 on
; the Falcon, clear of the P/Y alias in the lower 16K. The profile spikes
; reuse X:$1000-$1fff as their output buffer while no audio runs.
        org     x:$1000
ssi_buffer_a:
        ds      MT32_PERIOD_WORDS

        org     x:$1400
ssi_buffer_b:
        ds      MT32_PERIOD_WORDS

        IF      @DEF(LA32_REVERB_IMAGE)

; -----------------------------------------------------------------------------
; Boss reverb, one frame per iteration (internal P)
; -----------------------------------------------------------------------------
;
; Munt's BReverbModel, MT-32 room mode, integer renderer, in its default
; non-precise form:
;
;   dry  = ((inL >> 2) + (inR >> 2)) * dryAmp >> 8
;   entrance delay (576): link = oldest; new = ((last * $b0 >> 8) + dry) * $80 >> 8
;   three allpasses: new = link - (oldest >> 1); link = oldest + (new >> 1)
;   three combs: new = (last * $60 >> 8) - (link + (oldest * feedback >> 8))
;   outL = clip(c1[old] + c1[old]>>1 + c2[-687] + c2[-687]>>1 + c3[-1814])
;   outR = clip(c1[-1019] + ... + c2[-2072] + ... + c3[-1]),  wet = out * level >> 8
;
; where "last" is the word at a line's index, "oldest" the word after it,
; which the frame overwrites, and the taps are distances behind the new
; index. Every line is a modulo pointer: r0 entrance, r1-r3 allpasses at
; their next slot, r4/r5/r7 combs at their index, r6 the in-place stereo
; buffer. The tap reads use post-update addressing twice - forward by the
; offset and back - so they cost plain moves rather than indexed ones; comb
; 2 has two taps and reloads n5 between them. weirdMul is a fractional
; multiply by the factor << 15 and halving one by 2^22, both exact floors.

        org     p:$80

la32_reverb_run:
        do      #LA32_PROFILE_FRAMES,la32_reverb_done
la32_reverb_loop:
; dry input
        move    y:<rv_quarter,y0
        move    x:(r6)+,x0                  ; left
        mpy     x0,y0,a   x:(r6)-,x1        ; a1 = left >> 2; x1 = right; r6 back to the left slot
        mpy     x1,y0,b   y:<rv_dry,y1      ; b1 = right >> 2
        move    a1,x0
        add     x0,b      y:<rv_ffent,y0
        move    b1,x0
        mpy     x0,y1,a   y:(r0)+,x0        ; a1 = dry; x0 = entrance last; r0 -> oldest
        move    a1,y1                       ; y1 = dry
; entrance delay with its low-pass filter; the oldest word is the link
        mpy     x0,y0,a   y:(r0),x1         ; a1 = last * $b0 >> 8; x1 = link
        add     y1,a      y:<rv_lpf,y0
        move    a1,x0
        mpy     x0,y0,a   y:<rv_half,y0     ; a1 = new; y0 = half for the allpasses
        move    a1,y:(r0)
; allpass 0; the link travels in a from one allpass to the next
        tfr     x1,b      y:(r1),x0         ; b = link; x0 = oldest
        mpy     x0,y0,a                     ; a1 = oldest >> 1
        move    a1,y1
        sub     y1,b                        ; b1 = new
        move    b1,x1
        mpy     x1,y0,a   b,y:(r1)+         ; a1 = new >> 1; store, advance
        add     x0,a                        ; a1 = link
; allpass 1
        tfr     a,b       y:(r2),x0
        mpy     x0,y0,a
        move    a1,y1
        sub     y1,b
        move    b1,x1
        mpy     x1,y0,a   b,y:(r2)+
        add     x0,a
; allpass 2; the first comb's feedback factor rides on its last add
        tfr     a,b       y:(r3),x0
        mpy     x0,y0,a
        move    a1,y1
        sub     y1,b
        move    b1,x1
        mpy     x1,y0,a   b,y:(r3)+
        add     x0,a      y:<rv_fb1,y0
        move    a1,x1                       ; x1 = link into the combs
; comb 1; its oldest word is the first left tap
        move    y:(r4)+,x0                  ; last; r4 -> oldest
        move    y:(r4),y1                   ; oldest
        mpy     y1,y0,a   y:<rv_ffc,y0      ; a1 = oldest * feedback >> 8
        add     x1,a      y1,y:<rv_outl1    ; a1 = filter input; keep the tap
        mpy     x0,y0,b   y:<rv_fb2,y0      ; b1 = last * $60 >> 8; next feedback
        move    a1,y1
        sub     y1,b                        ; b1 = new
        move    b,y:(r4)                    ; store at the new index
; comb 2
        move    y:(r5)+,x0
        move    y:(r5),y1
        mpy     y1,y0,a   y:<rv_ffc,y0
        add     x1,a
        mpy     x0,y0,b   y:<rv_fb3,y0
        move    a1,y1
        sub     y1,b
        move    b,y:(r5)
; comb 3; its last word is the third right tap, and half is next
        move    y:(r7)+,x0
        move    y:(r7),y1
        mpy     y1,y0,a   y:<rv_ffc,y0
        add     x1,a      x0,y:<rv_outr3
        mpy     x0,y0,b   y:<rv_half,y0
        move    a1,y1
        sub     y1,b
        move    b,y:(r7)
; left output: 1.5 * comb 1's oldest + 1.5 * comb 2's tap + comb 3's tap,
; clipped and scaled by the wet level. A tap is read by stepping the comb's
; pointer forward by the offset and back, two plain moves that ride on the
; transfers and multiply-accumulates of the mix.
        move    y:<rv_outl1,x0
        tfr     x0,a      y:(r5)+n5,x1      ; a = tap 1; comb 2 to its left tap
        mac     x0,y0,a   y:(r5)-n5,x1      ; a1 = tap 1 + tap 1 >> 1; x1 = tap 2; back
        tfr     x1,b      y:(r7)+n7,y1      ; b = tap 2; comb 3 to its left tap
        mac     x1,y0,b   y:(r7)-n7,y1      ; b1 = tap 2 + tap 2 >> 1; y1 = tap 3; back
        move    b1,x1
        add     x1,a      y:<rv_max,x0
        add     y1,a      y:<rv_min,x1
        cmp     x0,a
        tgt     x0,a
        cmp     x1,a      y:<rv_wet,y1
        tlt     x1,a
        move    a1,x0
        mpy     x0,y1,a   y:(r4)+n4,x1      ; a1 = wet left; comb 1 to its right tap
        move    a1,x:(r6)+                  ; over the input
; right output: comb 1's tap, comb 2's second tap, comb 3's last word
        move    y:(r4)-n4,x0                ; x0 = tap 1; back
        move    y:<rv_n5r,n5
        tfr     x0,a      y:<rv_outr3,y1    ; a = tap 1; y1 = tap 3
        mac     x0,y0,a   y:(r5)+n5,x1      ; a1 = 1.5 * tap 1; comb 2 to its right tap
        move    y:(r5)-n5,x1                ; x1 = tap 2; back
        tfr     x1,b      y:<rv_n5l,n5      ; b = tap 2; the left offset again
        mac     x1,y0,b                     ; b1 = 1.5 * tap 2
        move    b1,x1
        add     x1,a      y:<rv_max,x0
        add     y1,a      y:<rv_min,x1
        cmp     x0,a
        tgt     x0,a
        cmp     x1,a      y:<rv_wet,y1
        tlt     x1,a
        move    a1,x0
        mpy     x0,y1,a
        move    a1,x:(r6)+                  ; wet right over the input
la32_reverb_done:
        rts

        ELSE

; -----------------------------------------------------------------------------
; LA32 synth partial, one frame per iteration (internal P)
; -----------------------------------------------------------------------------
;
; Munt's LA32WaveGenerator in fixed-point terms. With amp, pitch and cutoff
; constant, every per-sample quantity is a function of the 20-bit wave
; position WP:
;
;   SQ  = (WP >> 8) * (RWLF >> 4)           square-wave position, < 2^28
;   S4  = SQ >> 4                           what the code carries: every
;                                           boundary is a multiple of 16 and
;                                           only bits 4.. of SQ are ever used
;   half = S4 >= B3 (2^18 + HL + 2^18 in SQ units), R4 = S4 - (half ? B3 : 0)
;   segment within the half: rising sine below 2^14, linear below
;                            2^14 + HL4 (or LL4), falling sine above
;   square log   = sine[idx]<<2 (0 in the linear segment) + AMPT
;   resonance log = sine[(R4>>5)&1023]<<2 + (R4*DF)>>8 + RBASE + window,
;                   window = the square's sine<<2 (rising) or <<3 (falling)
;   sign: square negative in the negative half; resonance negative when
;         bit 15 of R4 differs from the half; sawtooth adds a cosine log to
;         both and flips both signs by bit 19 of WP + 2^18
;   unlog(v) = interpolateExp(v & 4095) >> (v >> 12)
;   out = +/-unlog(square) +/- unlog(resonance); L += (out*panL)>>13, R alike
;
; The exact kernel unlogs through two tables: one gives the first factor by
; the fraction, a second, indexed by the integer part, the power of two. Munt
; clamps every log to 65535, which unlogs to zero; the power table is zero
; from integer part 16 upwards and carries a zero guard word for -1, the
; lowest the resonance can reach, so no clamp is needed for the same result.
;
; The perceptual kernel factors each component instead: the square is a
; linear sine table entry times a per-block gain 2^(-AMPT/4096), the
; resonance a signed linear sine entry (sign in bit 10 of its index, the
; half's sign in the choice of a second table copy 1024 words up) times a
; gain read from one 4096-entry table by the top twelve bits of the rest of
; its log, and the sawtooth cosine multiplies their sum. That is one lookup
; and one multiply where the exact kernel needs two lookups, a multiply-
; accumulate and a sign multiply per component.
;
; Register contract on entry, set by command_profile: r3 = la_half0,
; r4/r5/r7 = FWD/ZERO/REV square tables, r6 = output, x0 = step, every m
; linear. r1 walks the selected half's record, r2 the selected segment
; table, r0 addresses the resonance sine; the unlog stage borrows r1 and r2.

        org     p:$80

la32_square_run:
        move    y:<la_step3,x0
        do      y:<la_frames,la32_square_done
la32_square_loop:
; phase advance: WP3 wraps naturally in 24 bits, bits 11-22 feed the multiply
        move    y:<la_wp3,a
        add     x0,a    y:<la_wphmask,x0
        move    a1,y:<la_wp3
        and     x0,a    y:<la_k7,y0
        move    a1,x0
        mpy     x0,y0,a y:<la_b3,x0
        asl     a       y:<la_rec1,r1    ; a1 = S4; r1 = half 1 record
; half: b = R4, r1 = that half's record
        tfr     a,b     y:<la_sh7,x1
        sub     x0,b
        tlt     a,b     r3,r1
        move    b1,y1                    ; y1 = R4
; resonance sign multiplier: sign base ^ ((R4 & $8000) << 8)
        mpy     y1,x1,a y:<la_sgnbit,x1  ; a0 = R4 << 8
        move    a0,b
        and     x1,b    y:(r1)+,x0       ; x0 = sign base; r1 -> linear length
        eor     x0,b
        move    b1,y:<la_rmul
; segment within the half: a = position inside a sine segment, r2 = table
        move    r4,r2
        tfr     y1,b    y:<la_2p14,x0
        tfr     y1,a    y:(r1)+,x1       ; x1 = linear length; r1 -> decay
        sub     x0,b    y:<la_sh5,y0
        tge     b,a     r5,r2
        sub     x1,b
        tge     b,a     r7,r2
; table addresses: n2 = square sine index, r0 = resonance sine; x0 = R4
        move    a1,x0
        mpy     x0,y0,a y:<la_m511,x1
        and     x1,a    y1,x0            ; a1 = square index; x0 = R4
        move    a1,n2
        tfr     y1,b    y:<la_m7fe0,x1
        and     x1,b    y:<la_rtab,a     ; b1 = R4 & $7fe0; a1 = table base
        move    b1,x1
        mac     x1,y0,a y:<la_aslope,x1  ; a1 = base + ((R4 >> 5) & 1023); x1 = amp slope
        move    a1,r0
; square log sample, the amp term ramped by the slope for this frame
        move    l:(r2+n2),b              ; b1 = sine<<2 or 0, b0 = window term
        move    y:<la_ampt,a
        add     x1,a    y:(r1)+,y1       ; a1 = amp term; y1 = decay << 15
        add     b,a     a1,y:<la_ampt    ; a1 = square log; the term stays ramped
        move    a1,y:<la_sqlog
; resonance log sample, its base ramped likewise
        move    y:<la_rbase,a
        add     x1,a    y:(r0),y0        ; a1 = base; y0 = sine<<2
        mac     x0,y1,a a1,y:<la_rbase   ; a1 = base + (R4 * decay) >> 8
        add     y0,a
        move    b0,x1
        add     x1,a    y:(r1),y1        ; a1 = resonance log; y1 = square sign
; unlog the resonance: b = +/-magnitude * 2^23
        tfr     a,b     y:<la_m4095,x1
        and     x1,b    y:<la_sh12,y0
        move    b1,r1                    ; r1 = fraction = unlog table address
        move    a1,x0
        move    y:<la_shtab,a
        mac     x0,y0,a x:(r1),x0        ; a1 = power entry address; x0 = unlog(frac)<<8
        move    a1,r2
        move    y:<la_rmul,y0
        move    x:(r2),x1                ; 2^(15 - integer part), or 0
        mpy     x0,x1,a                  ; a1 = magnitude
        move    a1,x0
        mpy     x0,y0,b
; unlog the square, accumulating into b
        move    y:<la_sqlog,a
        move    y:<la_m4095,x1
        and     x1,a    y:<la_sqlog,x0
        move    a1,r1
        move    y:<la_sh12,y0
        move    y:<la_shtab,a
        mac     x0,y0,a x:(r1),x0
        move    a1,r2
        move    y:<la_panl,y0
        move    x:(r2),x1
        mpy     x0,x1,a
        move    a1,x0
        mac     x0,y1,b                  ; b = (+/-m_sq +/- m_res) * 2^23
; pan into the interleaved accumulation buffer; reload the step for the next frame
        asl     b
        asl     b       y:<la_panr,y1    ; b1 = 2 * sample
        move    b1,x0
        move    x:(r6),a
        mac     x0,y0,a
        move    a1,x:(r6)+
        move    x:(r6),a
        mac     x0,y1,a y:<la_step3,x0
        move    a1,x:(r6)+
la32_square_done:
        rts

la32_saw_run:
        move    y:<la_step3,x0
        do      y:<la_frames,la32_saw_done
la32_saw_loop:
        move    y:<la_wp3,a
        add     x0,a    y:<la_wphmask,x0
        move    a1,y:<la_wp3
        and     x0,a    y:<la_k7,y0
        move    a1,x0
        mpy     x0,y0,a y:<la_b3,x0
        asl     a       y:<la_rec1,r1
        tfr     a,b     y:<la_sh7,x1
        sub     x0,b
        tlt     a,b     r3,r1
        move    b1,y1
        mpy     y1,x1,a y:<la_sgnbit,x1
        move    a0,b
        and     x1,b    y:(r1)+,x0
        eor     x0,b
        move    b1,y:<la_rmul
        move    r4,r2
        tfr     y1,b    y:<la_2p14,x0
        tfr     y1,a    y:(r1)+,x1
        sub     x0,b    y:<la_sh5,y0
        tge     b,a     r5,r2
        sub     x1,b
        tge     b,a     r7,r2
        move    a1,x0
        mpy     x0,y0,a y:<la_m511,x1
        and     x1,a    y1,x0
        move    a1,n2
        tfr     y1,b    y:<la_m7fe0,x1
        and     x1,b    y:<la_rtab,a
        move    b1,x1
        mac     x1,y0,a y:<la_aslope,x1
        move    a1,r0
        move    l:(r2+n2),b
        move    y:<la_ampt,a
        add     x1,a    y:(r1)+,y1
        add     b,a     a1,y:<la_ampt
        move    a1,y:<la_sqlog
        move    y:<la_rbase,a
        add     x1,a    y:(r0),y0
        mac     x0,y1,a a1,y:<la_rbase
        add     y0,a
        move    b0,x1
        add     x1,a    y:(r1),y1        ; a1 = resonance log; y1 = square sign
; sawtooth: add the synchronous cosine's log to both samples and flip both
; signs by the cosine's sign, bit 22 of WP3 + 2^21
        move    y:<la_wp3,b
        move    y:<la_pos21,x1
        add     x1,b    y:<la_mcos,x1
        move    b1,x0                    ; x0 = cosine position
        and     x1,b    y:<la_sh12,y0    ; b1 = position bits 11-21
        move    b1,x1
        move    y:<la_rtab,b
        mac     x1,y0,b y:<la_2p22,x1    ; b1 = table base + (position >> 12)
        move    b1,r0
        tfr     x0,b
        and     x1,b    y:(r0),x0        ; b1 = 0 or 2^22; x0 = cosine log
        asl     b                        ; b1 = 0 or $800000
        add     x0,a                     ; resonance log + cosine
        move    b1,x1
        move    y:<la_sqlog,b
        add     x0,b
        move    b1,y:<la_sqlog           ; square log + cosine
        move    y:<la_rmul,b
        eor     x1,b
        move    b1,y:<la_rmul
        tfr     y1,b
        eor     x1,b
        move    b1,y1                    ; y1 = square sign multiplier
; unlog both, sum, pan - as in the square loop
        tfr     a,b     y:<la_m4095,x1
        and     x1,b    y:<la_sh12,y0
        move    b1,r1
        move    a1,x0
        move    y:<la_shtab,a
        mac     x0,y0,a x:(r1),x0
        move    a1,r2
        move    y:<la_rmul,y0
        move    x:(r2),x1
        mpy     x0,x1,a
        move    a1,x0
        mpy     x0,y0,b
        move    y:<la_sqlog,a
        move    y:<la_m4095,x1
        and     x1,a    y:<la_sqlog,x0
        move    a1,r1
        move    y:<la_sh12,y0
        move    y:<la_shtab,a
        mac     x0,y0,a x:(r1),x0
        move    a1,r2
        move    y:<la_panl,y0
        move    x:(r2),x1
        mpy     x0,x1,a
        move    a1,x0
        mac     x0,y1,b
        asl     b
        asl     b       y:<la_panr,y1
        move    b1,x0
        move    x:(r6),a
        mac     x0,y0,a
        move    a1,x:(r6)+
        move    x:(r6),a
        mac     x0,y1,a y:<la_step3,x0
        move    a1,x:(r6)+
la32_saw_done:
        rts

; Perceptual kernel. Positions, segments and the resonance's log-domain rest
; (decay, window, amp base) are computed exactly as above; the record holds
; the linear length, the half's signed sine table base, the decay factor and
; the signed square gain.
la32_psquare_run:
        move    y:<la_step3,x0
        do      y:<la_frames,la32_psquare_done
la32_psquare_loop:
; phase advance
        move    y:<la_wp3,a
        add     x0,a    y:<la_wphmask,x0
        move    a1,y:<la_wp3
        and     x0,a    y:<la_k7,y0
        move    a1,x0
        mpy     x0,y0,a y:<la_b3,x0
        asl     a       y:<la_rec1,r1    ; a1 = S4; r1 = half 1 record
; half: b = R4, r1 = that half's record
        tfr     a,b
        sub     x0,b    y:<la_2p14,x0
        tlt     a,b     r3,r1
        move    b1,y1                    ; y1 = R4
; segment within the half: a = position inside a sine segment, r2 = table
        move    r4,r2
        tfr     y1,a    y:(r1)+,x1       ; x1 = linear length; r1 -> sine table base
        tfr     y1,b    y:<la_sh5,y0
        sub     x0,b
        tge     b,a     r5,r2
        sub     x1,b
        tge     b,a     r7,r2
; table addresses: n2 = square sine index, r0 = signed resonance sine; x0 = R4
        move    a1,x0
        mpy     x0,y0,a y:<la_m511,x1
        and     x1,a    y1,x0            ; a1 = square index; x0 = R4
        move    a1,n2
        tfr     y1,b    y:<la_mffe0,x1
        and     x1,b    y:(r1)+,a        ; b1 = R4 & $ffe0; a1 = the half's table base; r1 -> decay
        move    b1,x1
        mac     x1,y0,a                  ; a1 = base + ((R4 >> 5) & 2047)
        move    a1,r0
; square component and the rest of the resonance log
        move    l:(r2+n2),b              ; b1 = linear sine * 4 or full scale; b0 = window log
        move    y:(r1)+,y1               ; y1 = decay << 15; r1 -> square gain
        move    y:<la_rbase,a
        mac     x0,y1,a y:(r1),y1        ; a1 = rbase + (R4 * decay) >> 8; y1 = signed square gain
        move    b0,x1
        add     x1,a    y:<la_m65535,x1  ; a1 = rest of the resonance log
        move    b1,x0
        mpy     x0,y1,b y:<la_sh4,y0     ; b1 = square component; y0 = 2^19
; resonance component: gain[rest >> 4] times the signed sine
        cmp     x1,a
        tgt     x1,a                     ; the gain table ends at 65535
        move    a1,x0
        move    y:<la_gtab,a
        mac     x0,y0,a y:(r0),x1        ; a1 = gain entry address; x1 = signed sine * 4
        move    a1,r1
        move    y:<la_panl,y0
        move    y:(r1),x0                ; x0 = gain, Q21
        mac     x0,x1,b y:<la_f,y1       ; b1 = sample; y1 = F
; the amp ramp: scale by F, then F *= r for the next frame
        move    b1,x0
        mpyr    x0,y1,b y:<la_r,x1       ; b1 = the sample scaled by F; x1 = r
        mpy     y1,x1,a                  ; a1 = F * r, Q22
        asl     a
        move    a,y:<la_f                ; Q23, limited at one
; pan into the interleaved accumulation buffer; reload the step for the next frame
        move    b1,x0
        move    x:(r6),a
        mac     x0,y0,a y:<la_panr,y1
        move    a1,x:(r6)+
        move    x:(r6),a
        mac     x0,y1,a y:<la_step3,x0
        move    a1,x:(r6)+
la32_psquare_done:
        rts

la32_psaw_run:
        move    y:<la_step3,x0
        do      y:<la_frames,la32_psaw_done
la32_psaw_loop:
        move    y:<la_wp3,a
        add     x0,a    y:<la_wphmask,x0
        move    a1,y:<la_wp3
        and     x0,a    y:<la_k7,y0
        move    a1,x0
        mpy     x0,y0,a y:<la_b3,x0
        asl     a       y:<la_rec1,r1
        tfr     a,b
        sub     x0,b    y:<la_2p14,x0
        tlt     a,b     r3,r1
        move    b1,y1
        move    r4,r2
        tfr     y1,a    y:(r1)+,x1
        tfr     y1,b    y:<la_sh5,y0
        sub     x0,b
        tge     b,a     r5,r2
        sub     x1,b
        tge     b,a     r7,r2
        move    a1,x0
        mpy     x0,y0,a y:<la_m511,x1
        and     x1,a    y1,x0
        move    a1,n2
        tfr     y1,b    y:<la_mffe0,x1
        and     x1,b    y:(r1)+,a
        move    b1,x1
        mac     x1,y0,a
        move    a1,r0
        move    l:(r2+n2),b
        move    y:(r1)+,y1
        move    y:<la_rbase,a
        mac     x0,y1,a y:(r1),y1
        move    b0,x1
        add     x1,a    y:<la_m65535,x1
        move    b1,x0
        mpy     x0,y1,b y:<la_sh4,y0
        cmp     x1,a
        tgt     x1,a
        move    a1,x0
        move    y:<la_gtab,a
        mac     x0,y0,a y:(r0),x1
        move    a1,r1
        move    y:<la_panl,y0
        move    y:(r1),x0
        mac     x0,x1,b                  ; b1 = square + resonance
; sawtooth: the signed cosine multiplies the sum
        move    y:<la_wp3,a
        move    y:<la_pos21,x1
        add     x1,a    y:<la_mcos11,x1
        and     x1,a    y:<la_sh12,y0    ; a1 = cosine position bits 12-22
        move    a1,x1
        move    y:<la_ctab,a
        mac     x1,y0,a                  ; a1 = cosine entry address
        move    a1,r0
        move    b1,x0                    ; x0 = sum
        move    x:(r0),y1                ; y1 = signed cosine * 1024
        mpy     x0,y1,b y:<la_f,y1       ; b1 = sum * cosine / 8192; y1 = F
; the amp ramp: scale by F, then F *= r for the next frame
        move    b1,x0
        mpyr    x0,y1,b y:<la_r,x1       ; b1 = the sample scaled by F; x1 = r
        mpy     y1,x1,a y:<la_panl,y0    ; a1 = F * r, Q22; y0 = left pan
        asl     a
        move    a,y:<la_f                ; Q23, limited at one
        move    b1,x0
        move    x:(r6),a
        mac     x0,y0,a y:<la_panr,y1
        move    a1,x:(r6)+
        move    x:(r6),a
        mac     x0,y1,a y:<la_step3,x0
        move    a1,x:(r6)+
la32_psaw_done:
        rts

        ENDIF

; -----------------------------------------------------------------------------
; Kernel (external P; the transport is not cycle-critical)
; -----------------------------------------------------------------------------

        org     p:$200

start:
        movep   #1,x:m_pbc              ; enable the Falcon host port
        movep   #$1f8,x:m_pcc           ; Port C pins to SSI function; they
                                        ; reset to GPIO, leaving the slave
                                        ; SSI clockless on real hardware
        movep   #0,x:m_bcr              ; reset leaves fifteen wait states on
                                        ; every external access, and the
                                        ; Dsp_ExecBoot path bypasses the TOS
                                        ; loader that would clear them; the
                                        ; Falcon SRAM needs none and Hatari
                                        ; ignores the register entirely
        movep   #$3000,x:m_ipr          ; SSI interrupt priority level 2
        andi    #$fc,mr                 ; reset leaves I1:I0=11 masking IPL 2;
                                        ; the SSI ISR needs the mask lowered
        move    #>-1,m0                 ; linear addressing for the period
        move    #>-1,m1                 ; buffers and the tone table
        move    #>-1,m4

        jsr     la32_tables_install
        jsr     mt32_reset

; Idle command loop. Everything that needs the codec running is dispatched
; from one of the two audio loops below instead.
command_loop:
        jclr    #0,x:m_hsr,*            ; wait for host receive data full
        movep   x:m_hrx,x1
        move    x1,y:last_command

        move    x1,a
        move    #>$ff0000,y0
        and     y0,a1                   ; isolate opcode

        move    #>MT32_CMD_PING,x0
        cmp     x0,a
        jeq     command_ping

        move    #>MT32_CMD_RESET,x0
        cmp     x0,a
        jeq     command_reset

        move    #>MT32_CMD_SET_TONE,x0
        cmp     x0,a
        jeq     command_set_tone

        move    #>MT32_CMD_START_TONE,x0
        cmp     x0,a
        jeq     command_start_tone

        move    #>MT32_CMD_START_STREAM,x0
        cmp     x0,a
        jeq     command_start_stream

        move    #>MT32_CMD_QUERY_TIME,x0
        cmp     x0,a
        jeq     command_query_time

        move    #>MT32_CMD_QUERY_PERIODS,x0
        cmp     x0,a
        jeq     command_query_periods

        move    #>MT32_CMD_PROFILE_PARTIAL,x0
        cmp     x0,a
        jeq     command_profile

        move    #>MT32_CMD_CONTROL_RUN,x0
        cmp     x0,a
        jeq     command_control

command_unknown:
        move    #>MT32_REPLY_ERROR,a
        jsr     send_reply
        jmp     command_loop

command_ping:
        move    #>MT32_REPLY_HELLO,a
        jsr     send_reply
        jmp     command_loop

command_reset:
        jsr     mt32_reset
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

; The low 16 bits are the per-frame phase increment; see MT32_TONE_A440_STEP
; for the conversion the host uses.
command_set_tone:
        move    y:last_command,a
        move    #>$00ffff,y0
        and     y0,a1
        move    a1,y:tone_step
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

command_query_time:
        move    y:ssi_frame_count,a
        jsr     send_reply
        jmp     command_loop

command_query_periods:
        move    y:ssi_period_count,a
        jsr     send_reply
        jmp     command_loop

; -----------------------------------------------------------------------------
; Profile spike: MT32_CMD_PROFILE_PARTIAL
; -----------------------------------------------------------------------------

; Install the selected run's configuration block over the kernel's
; configuration words, then render, fold the output buffer into a checksum
; and reply with it. The render loops carry the profiler's start and end
; labels; everything here is outside the bracket.
; in:  a1 = run index
; out: r1 = the configuration block, r0 = past its image
profile_install:
        move    a1,b
        rep     #4
        asl     b                       ; run index * 16 ...
        add     a,b
        add     a,b                     ; ... + 2: LA32_CONFIG_WORDS words per run
        move    #>la32_cfg_image,x0
        add     x0,b
        move    b1,r0
        IF      @DEF(LA32_REVERB_IMAGE)
        move    #<rv_input,r1
        ELSE
        move    #<la_step3,r1
        ENDIF
        do      #LA32_CONFIG_WORDS,profile_installed
        move    p:(r0)+,x0
        move    x0,y:(r1)+
profile_installed:
        rts

; Fold the output buffer into the reply checksum, h = (2h + word) mod 2^24.
profile_fold:
        move    #>LA32_OUTPUT_BASE,r6
        move    #>LA32_OUTPUT_WORDS,x0
        clr     a
        do      x0,profile_folded
        move    x:(r6)+,x1
        asl     a
        add     x1,a
profile_folded:
        rts

        IF      @DEF(LA32_REVERB_IMAGE)

; Reverb image: the input frames are already in X:$1000, delivered by the P
; alias; clear the delay lines, point every modulo register at its line and
; run the loop over the buffer in place.
command_profile:
        move    y:last_command,a
        move    #>$0000ff,x0
        and     x0,a
        jsr     profile_install
        move    y:<rv_kernel,a
        move    #>2,x0
        cmp     x0,a
        jne     command_unknown
        jsr     reverb_prepare
        jsr     la32_reverb_run
        jsr     profile_fold
        jsr     send_reply
        jmp     command_loop

; Control runs need the partial image.
command_control:
        jmp     command_unknown

; Silence the seven lines, then set the pointers as Munt's indices start:
; the entrance and the combs at slot 0, the allpasses at slot 1, which is
; the slot their first frame reads and writes.
reverb_prepare:
        clr     a
        move    #>-1,m0
        move    #>RV_ENT_BASE,r0
        do      #RV_ENT_SIZE,reverb_ent_cleared
        move    a1,y:(r0)+
reverb_ent_cleared:
        move    #>RV_AP0_BASE,r0
        do      #RV_AP0_SIZE,reverb_ap0_cleared
        move    a1,y:(r0)+
reverb_ap0_cleared:
        move    #>RV_AP1_BASE,r0
        do      #RV_AP1_SIZE,reverb_ap1_cleared
        move    a1,y:(r0)+
reverb_ap1_cleared:
        move    #>RV_AP2_BASE,r0
        do      #RV_AP2_SIZE,reverb_ap2_cleared
        move    a1,y:(r0)+
reverb_ap2_cleared:
        move    #>RV_COMB1_BASE,r0
        do      #RV_COMB1_SIZE,reverb_comb1_cleared
        move    a1,y:(r0)+
reverb_comb1_cleared:
        move    #>RV_COMB2_BASE,r0
        do      #RV_COMB2_SIZE,reverb_comb2_cleared
        move    a1,y:(r0)+
reverb_comb2_cleared:
        move    #>RV_COMB3_BASE,r0
        do      #RV_COMB3_SIZE,reverb_comb3_cleared
        move    a1,y:(r0)+
reverb_comb3_cleared:
        move    #>RV_ENT_BASE,r0
        move    #>RV_ENT_SIZE-1,m0
        move    #>RV_AP0_BASE+1,r1
        move    #>RV_AP0_SIZE-1,m1
        move    #>RV_AP1_BASE+1,r2
        move    #>RV_AP1_SIZE-1,m2
        move    #>RV_AP2_BASE+1,r3
        move    #>RV_AP2_SIZE-1,m3
        move    #>RV_COMB1_BASE,r4
        move    #>RV_COMB1_SIZE-1,m4
        move    #>RV_TAP_R1,n4
        move    #>RV_COMB2_BASE,r5
        move    #>RV_COMB2_SIZE-1,m5
        move    y:<rv_n5l,n5
        move    #>RV_COMB3_BASE,r7
        move    #>RV_COMB3_SIZE-1,m7
        move    #>RV_TAP_L3,n7
        move    #>LA32_OUTPUT_BASE,r6
        move    #>-1,m6
        rts

; Nothing to install: the reverb image carries no boot-time tables.
la32_tables_install:
        rts

        ELSE

; Partial image: install, clear the output buffer, render the whole run
; with the kernel and wave the configuration names, fold and reply.
command_profile:
        move    y:last_command,a
        move    #>$0000ff,x0
        and     x0,a
        jsr     profile_install
        move    #>LA32_PROFILE_FRAMES,x0
        move    x0,y:<la_frames
        move    #>0,x0
        move    x0,y:<la_aslope         ; the amp stands for the whole run
        move    #>$7fffff,x0
        move    x0,y:<la_f
        move    #>$400000,x0
        move    x0,y:<la_r
        jsr     profile_prepare
        jsr     la32_kernel_run
        jsr     profile_fold
        jsr     send_reply
        jmp     command_loop

; Start the wave one step early, so the first frame is Munt's position
; zero, clear the output buffer, and set what the kernels expect: every m
; linear, r3 = la_half0, r4/r5/r7 = the FWD, ZERO and REV square tables
; 512 words apart, r6 = the output buffer.
profile_prepare:
        clr     a
        move    y:<la_step3,x0
        sub     x0,a
        move    a1,y:<la_wp3
        move    #>LA32_OUTPUT_BASE,r6
        move    #>LA32_OUTPUT_WORDS,x0
        clr     a
        do      x0,profile_prepare_cleared
        move    a1,x:(r6)+
profile_prepare_cleared:
        move    #>-1,m0
        move    #>-1,m1
        move    #>-1,m2
        move    #>-1,m3
        move    #>-1,m5
        move    #>-1,m6
        move    #>-1,m7
        move    #<la_half0,r3
        move    y:<la_sqbase,a
        move    #>512,x0
        move    a1,r4
        add     x0,a
        move    a1,r5
        add     x0,a
        move    a1,r7
        move    #>LA32_OUTPUT_BASE,r6
        rts

; Render la_frames frames with the kernel and wave the configuration names.
; A reverb run's kernel word renders nothing: it needs the other image.
la32_kernel_run:
        move    y:<la_kernel,a
        tst     a
        jne     la32_kernel_perceptual
        move    y:<la_saw,a
        tst     a
        jne     la32_saw_run
        jmp     la32_square_run
la32_kernel_perceptual:
        move    #>1,x0
        cmp     x0,a
        jne     la32_kernel_none
        move    y:<la_saw,a
        tst     a
        jne     la32_psaw_run
        jmp     la32_psquare_run
la32_kernel_none:
        rts

; -----------------------------------------------------------------------------
; Control-rate spike: MT32_CMD_CONTROL_RUN
; -----------------------------------------------------------------------------

; Take the payload from the host into the record area - the kernel's static
; constants, the pulse-width and resonance terms, the block length and
; count, then one record per block - install the constants, and render the
; run block by block, deriving the kernel's constants from each record
; first. The block loop is what the profiler brackets; the derivation
; before it only gives the wave its starting position.
command_control:
        move    #>MT32_REPLY_BLOCK_READY,a
        jsr     send_reply
        move    #>LA32_CONTROL_HEADER_Y,r0
        move    #>-1,m0
        do      #LA32_CONTROL_HEADER,command_control_header
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,y:(r0)+
command_control_header:
        move    #>LA32_CONTROL_HEADER_Y,r1
        move    #<la_step3,r2
        do      #LA32_CONFIG_WORDS,command_control_installed
        move    y:(r1)+,x0
        move    x0,y:(r2)+
command_control_installed:
        move    y:(r1)+,x0
        move    x0,y:>la_epw
        move    y:(r1)+,x0
        move    x0,y:>la_ras
        move    y:(r1)+,x0
        move    x0,y:>la_blocklen       ; the nominal block length, unused
        move    y:(r1)+,a
        move    a1,y:<la_blocks
        move    #>LA32_CONTROL_RECORDS,r0
        move    r0,y:>la_recbase
        move    a1,b
        asl     b
        asl     b
        add     a,b                     ; five words per record
        move    b1,x0
        do      x0,command_control_records
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,x:(r0)+
command_control_records:
        move    #>-1,m2                 ; the derivation walks the records with r2
        jsr     la32_kernel_entry
        move    #>-1,x0
        move    x0,y:>la_prev_pitch
        move    x0,y:>la_prev_c
        move    y:>la_recbase,x0
        move    x0,y:>la_record
        jsr     la32_block_derive
        jsr     la32_block_positions
        jsr     profile_prepare
        move    y:>la_recbase,x0
        move    x0,y:>la_record
        move    #>-1,x0                 ; block 0 derives again inside the window
        move    x0,y:>la_prev_pitch
        move    x0,y:>la_prev_c
        ; Per record: derive what it changed. When the position constants
        ; changed, render the first frame with the previous record's,
        ; install, and render the rest, as Munt orders them; otherwise
        ; render the record's frames in one call.
        do      y:<la_blocks,la32_control_done
la32_control_loop:
        jsr     la32_block_derive
        move    y:<la_poschg,a
        tst     a
        jeq     la32_control_steady
        move    #>1,x0
        move    x0,y:<la_frames
        move    y:<la_entry,r0
        nop
        jsr     (r0)
        jsr     la32_block_positions
        move    y:<la_rest,a
        tst     a
        jeq     la32_control_next       ; a record of one frame is done
        move    a1,y:<la_frames
        move    y:<la_entry,r0
        nop
        jsr     (r0)
        jmp     la32_control_next
la32_control_steady:
        move    y:<la_entry,r0
        nop
        jsr     (r0)
la32_control_next:
        nop
la32_control_done:
        jsr     profile_fold
        jsr     send_reply
        jmp     command_loop

; The run's kernel entry, from the kernel and wave words, so a block costs
; one indirect call instead of the compare chain.
la32_kernel_entry:
        move    y:<la_kernel,b
        tst     b
        jne     la32_kernel_entry_perceptual
        move    #>la32_square_run,a
        move    #>la32_saw_run,x1
        move    y:<la_saw,b
        tst     b
        tne     x1,a
        move    a1,y:<la_entry
        rts
la32_kernel_entry_perceptual:
        move    #>la32_psquare_run,a
        move    #>la32_psaw_run,x1
        move    y:<la_saw,b
        tst     b
        tne     x1,a
        move    a1,y:<la_entry
        rts

; Move a block's pending position constants into the kernel's words.
la32_block_positions:
        move    y:>la_pend_step3,x0
        move    x0,y:<la_step3
        move    y:>la_pend_k7,x0
        move    x0,y:<la_k7
        move    y:>la_pend_b3,x0
        move    x0,y:<la_b3
        move    y:<la_kernel,a
        tst     a
        jne     la32_positions_perceptual
        move    y:<la_scr_hl4,x0
        move    x0,y:<la_half0+1
        move    y:<la_scr_ll4,x0
        move    x0,y:<la_half1+1
        rts
la32_positions_perceptual:
        move    y:<la_scr_hl4,x0
        move    x0,y:<la_half0
        move    y:<la_scr_ll4,x0
        move    x0,y:<la_half1
        rts

; Derive the kernel's block constants from one control record - the frames
; it holds for, then amp >> 10, the amp's slope per frame, pitch and
; cutoff >> 3 - as
; LA32WaveGenerator does per sample, but only what the record changed: the step when the pitch moved; the effective
; cutoff, the resonance wave-length factor, the segment lengths and the
; cutoff's two log terms when the cutoff moved; the amp's two words and the
; perceptual gain every block, since the amp moves in every envelope phase.
; The host clamps the cutoff. interpolateExp comes from the exact unlog
; table, which holds it << 8 at X:0; a right shift by a data-dependent
; count is a multiply by a power of two from la_pow, a left shift runs asl
; under rep by at least one. Sets la_poschg when the position constants -
; step, k7, b3, the linear lengths - changed. Scratches r0-r2 and every
; data register; the kernels' r3-r7 survive.
la32_block_derive:
        move    y:>la_record,r2
        nop
        move    x:(r2)+,a               ; the frames this record holds for
        move    a1,y:<la_frames
        move    #>1,x1
        sub     x1,a
        move    a1,y:<la_rest
        move    x:(r2)+,a               ; amp >> 10
        move    a1,y:<la_scr_ampt
        move    x:(r2)+,a               ; the amp's slope per frame
        move    a1,y:<la_aslope
        move    x:(r2)+,x0              ; pitch
        move    x:(r2)+,b               ; cutoff >> 3
        move    r2,y:>la_record
        move    #>0,x1
        move    x1,y:<la_poschg
; step = (interpolateExp(~pitch & 4095) << (pitch >> 12)) >> 8, even, << 3
        move    x0,a
        move    y:>la_prev_pitch,x1
        cmp     x1,a
        jeq     la32_derive_pitch_same
        move    x0,y:>la_prev_pitch
        move    y:<la_m4095,x1
        not     a
        and     x1,a
        move    a1,r0                   ; ~pitch & 4095
        move    y:<la_sh12,y0
        mpy     x0,y0,a                 ; pitch >> 12
        move    a1,x1
        move    #>la_pow+7,a
        add     x1,a
        move    a1,r1                   ; 2^(7 + pitch >> 12): the shift by 16 - (pitch >> 12)
        move    x:(r0),x1
        move    y:(r1),y0
        mpy     x1,y0,a                 ; the step, odd bit and all
        move    #>$fffffe,x1
        and     x1,a
        move    a1,x1
        move    x1,a
        rep     #3
        asl     a
        move    a1,y:>la_pend_step3
        move    #>1,x1
        move    x1,y:<la_poschg
la32_derive_pitch_same:
; the cutoff's constants, when it moved
        move    y:>la_prev_c,x1
        cmp     x1,b
        jeq     la32_derive_cutoff_same
        move    b1,y:>la_prev_c
        move    #>1,x1
        move    x1,y:<la_poschg
; effective cutoff: (cutoff - middle) >> 7 above the middle, else 0
        move    #>$400000,x1            ; 128 << 15
        tfr     b,a
        sub     x1,a
        move    #>0,x0
        tmi     x0,a
        move    a1,x1
        move    #>$10000,y0             ; 2^16: a right shift by 7
        mpy     x1,y0,a
        move    a1,y:>la_scr_ecv
; resonance wave-length factor << 4 = (interpolateExp << 8 >> 5) << (ecv >> 12 + 1)
        move    y:<la_m4095,x1
        tfr     a,b
        not     b
        and     x1,b
        move    b1,r0
        move    a1,x1
        move    y:<la_sh12,y0
        mpy     x1,y0,a                 ; ecv >> 12
        move    #>1,y1
        add     y1,a
        move    a1,x1                   ; the left shift, at least one
        move    x:(r0),y0
        move    y:<la_sh5,x0            ; 2^18: a right shift by 5
        mpy     y0,x0,a
        rep     x1
        asl     a
        move    a1,y:>la_scr_rwlf4
; (rwlf >> 4) << 7 = (rwlf4 >> 1) & ~127, shifted in the accumulator: at the
; cutoff ceiling rwlf4 reaches 2^23, one bit more than a data register holds
        asr     a
        move    #>$ffff80,x1
        and     x1,a
        move    a1,y:>la_pend_k7
; high linear length >> 4 = (interpolateExp << 8 >> 6) << (arg >> 12 + 1) - 2^15
; while the pulse-width term is below the effective cutoff, else 0
        move    y:>la_scr_ecv,a
        move    y:>la_epw,x1
        cmp     x1,a
        jle     la32_derive_no_high
        sub     x1,a
        move    a1,x0
        move    y:<la_m4095,x1
        tfr     a,b
        not     b
        and     x1,b
        move    b1,r0
        move    y:<la_sh12,y0
        mpy     x0,y0,a                 ; arg >> 12
        move    #>1,y1
        add     y1,a
        move    a1,x1
        move    x:(r0),y0
        move    #>$20000,x0             ; 2^17: a right shift by 6
        mpy     y0,x0,a
        rep     x1
        asl     a
        move    #>$8000,x1
        sub     x1,a
        move    a1,y:<la_scr_hl4
        jmp     la32_derive_high_done
la32_derive_no_high:
        move    #>0,x1
        move    x1,y:<la_scr_hl4
la32_derive_high_done:
; the negative half's start and the low linear length, S4 units
        move    y:<la_scr_hl4,a
        move    #>$8000,x1
        add     x1,a
        move    a1,y:>la_pend_b3
        move    y:>la_scr_rwlf4,a
        move    #>$10000,x1
        sub     x1,a
        move    y:<la_scr_hl4,x1
        sub     x1,a
        move    a1,y:<la_scr_ll4
; the cutoff's square amp term, and the resonance base without the amp
        move    y:>la_prev_c,x1
        move    #>$400000,b
        sub     x1,b                    ; middle - cutoff
        jle     la32_derive_cutoff_high
        move    b1,x1
        move    #>$20000,y0             ; 2^17: a right shift by 6
        mpy     x1,y0,b
        move    b1,x1
        move    x1,y:>la_cut_amp
        move    x1,b
        move    #>31743,y1
        add     y1,b                    ; the resonance's cutoff term
        jmp     la32_derive_cutoff_done
la32_derive_cutoff_high:
        move    #>0,x1
        move    x1,y:>la_cut_amp
        move    y:>la_prev_c,x1
        move    #>$480000,b             ; 144 << 15: the decay threshold
        cmp     x1,b
        jle     la32_derive_cutoff_zero
        move    x1,b
        move    #>$400000,x1
        sub     x1,b                    ; cutoff - middle
        move    b1,x1
        move    #>$2000,y0              ; 2^13: a right shift by 10
        mpy     x1,y0,b
        move    b1,x1
        move    y:<la_rtab,b
        add     x1,b
        move    b1,r0
        nop
        move    y:(r0),b                ; logsin9 << 2
        jmp     la32_derive_cutoff_done
la32_derive_cutoff_zero:
        move    #>0,b
la32_derive_cutoff_done:
        move    y:>la_ras,a
        move    b1,x1
        add     x1,a
        move    #>4096,x1
        sub     x1,a
        move    a1,y:<la_cut_res
la32_derive_cutoff_same:
; the amp's words, every record
        move    y:<la_kernel,b
        tst     b
        jne     la32_derive_amp_perceptual
; exact kernels: la_ampt and la_rbase one slope before the record's first
; frame; the kernels add the slope each frame before they use them
        move    y:<la_scr_ampt,a
        move    y:<la_aslope,x1
        sub     x1,a
        move    a1,y1
        move    y:<la_cut_res,x1
        add     x1,a
        move    a1,y:<la_rbase
        move    y1,a
        move    y:>la_cut_amp,x1
        add     x1,a
        move    a1,y:<la_ampt
        rts
; perceptual kernels: the gain and the resonance base at the record's
; louder end, and the sum scaled by F, which the kernel multiplies by r
; each frame - r = 2^(-slope/4096) from F = 1 when the amp falls or
; stands, r = 2^(|slope|/4096) from F = 2^(slope * frames / 4096) when it
; rises, so F reaches 1 on the record's last frame
la32_derive_amp_perceptual:
        move    y:<la_aslope,a
        tst     a
        jlt     la32_derive_amp_rising
        move    #>LA32_RAMP_STEEP,x1
        cmp     x1,a
        jge     la32_derive_amp_falling_steep
        move    #>LA32_RAMP_FALLING,x1  ; r = 2^(-slope/4096) from the table
        add     x1,a
        move    a1,r0
        nop
        move    y:(r0),x1
        move    x1,y:<la_r
        jmp     la32_derive_amp_falling
la32_derive_amp_falling_steep:
        move    a1,x1
        jsr     la32_derive_pow2        ; a1 = 2^(-slope/4096) * 2^21
        jsr     la32_derive_unbias
        asl     a                       ; Q22
        move    a1,y:<la_r
la32_derive_amp_falling:
        move    #>$7fffff,x1
        move    x1,y:<la_f
        move    y:<la_scr_ampt,y1       ; the basis: the record's first frame
        jmp     la32_derive_amp_basis
la32_derive_amp_rising:
        neg     a
        move    a1,x0                   ; x0 = |slope|
        move    y:<la_frames,y0
        mpy     x0,y0,b                 ; b = 2 * |slope| * frames
        asr     b
        move    b0,x1                   ; x1 = |slope| * frames
        move    y:<la_scr_ampt,b
        sub     x1,b
        move    #>0,y1
        tmi     y1,b                    ; a truncated slope never lands below zero
        move    b1,y1                   ; the basis: the record's last frame
        jsr     la32_derive_pow2        ; a1 = 2^(-|slope| * frames / 4096) * 2^21
        jsr     la32_derive_unbias
        asl     a
        asl     a                       ; Q23
        move    a1,y:<la_f
        move    #>LA32_RAMP_STEEP,x1
        move    x0,b
        cmp     x1,b
        jge     la32_derive_amp_rising_steep
        move    #>LA32_RAMP_RISING,x1   ; r = 2^(|slope|/4096) from the table
        add     x1,b
        move    b1,r0
        nop
        move    y:(r0),x1
        move    x1,y:<la_r
        jmp     la32_derive_amp_basis
la32_derive_amp_rising_steep:
        move    #>4096,b
        sub     x0,b                    ; b1 = 4096 - |slope|
        move    #>0,x1
        tmi     x1,b
        move    b1,x1
        jsr     la32_derive_pow2        ; a1 = 2^(|slope|/4096) * 2^20
        jsr     la32_derive_unbias
        asl     a
        asl     a                       ; Q22
        move    a,y:<la_r               ; limited at two
la32_derive_amp_basis:
        move    y1,a
        move    y:<la_cut_res,x1
        add     x1,a
        move    a1,y:<la_rbase
        move    y1,a
        move    y:>la_cut_amp,x1
        add     x1,a
        move    a1,y:<la_ampt
; the perceptual gain = 2^(-ampt/4096) * 2^21 from the amp term, signed per half
        move    a1,x1
        jsr     la32_derive_pow2
        move    a1,x1
        move    x1,y:<la_half0+3
        move    x1,a
        neg     a
        move    a1,y:<la_half1+3
        rts

; 2^(-x1/4096) as a Q21 value in a1, from the exact unlog table:
; interpolateExp(x1 & 4095) << 8 >> (x1 >> 12), the shift a multiply by a
; power of two from la_pow. Scratches a, b, x1, y0, r0 and r1.
la32_derive_pow2:
        move    x1,a
        move    y:<la_m4095,y0
        and     y0,a
        move    a1,r0                   ; the fraction's table index
        move    y:<la_sh12,y0
        mpy     x1,y0,a                 ; the shift, 0 to 32
        move    a1,b
        move    #>la_pow+23,a
        sub     b,a
        move    a1,r1                   ; 2^(23 - shift), zero beyond the table
        move    x:(r0),y0
        move    y:(r1),x1
        mpy     x1,y0,a                 ; the value, except for a shift of none
        tst     b
        teq     y0,a                    ; a shift of none keeps the table value
        rts

; Munt's exponent table starts at 8191 of 8192, a bias the ramp's factors
; would compound frame after frame: a = a1 + (a1 >> 13), clean below a1.
la32_derive_unbias:
        move    a1,x1
        move    #>$000400,y0            ; 2^10: a right shift by 13
        mpy     x1,y0,a
        move    a1,y0
        move    x1,a
        add     y0,a
        rts

; Copy the fixed constants into internal Y and the first page of the unlog
; table into internal X from their P images. Both are the only LA32 data the
; P alias cannot deliver directly; every other table lands in place.
la32_tables_install:
        move    #>la32_const_image,r1
        move    #<la_wphmask,r4
        do      #LA32_CONST_WORDS,la32_const_installed
        move    p:(r1)+,a
        move    a1,y:(r4)+
la32_const_installed:
        move    #>LA32_UNLOG_IMAGE_P,r1
        move    #<LA32_UNLOG_X,r4
        do      #LA32_UNLOG_COPY,la32_unlog_installed
        move    p:(r1)+,a
        move    a1,x:(r4)+
la32_unlog_installed:
        ; the powers of two the block derivation multiplies by, guarded
        ; below by zeros and above by one for the shift that keeps the value
        move    #>la_pow_guard,r4
        clr     a
        do      #9,la32_pow_guarded
        move    a1,y:(r4)+
la32_pow_guarded:
        move    #>1,a
        do      #23,la32_pow_built
        move    a1,y:(r4)+
        asl     a
la32_pow_built:
        clr     a
        move    a1,y:(r4)+
        rts

        ENDIF

; -----------------------------------------------------------------------------
; Source 1: DSP-generated tone
; -----------------------------------------------------------------------------

; Prove the codec path with no host data dependency at all: crossbar clock,
; SSI framing, DAC routing and the period handoff are all exercised, and a
; frozen or absent SSI clock shows up as silence with a stalled frame count
; rather than as a plausible-sounding wrong result.
command_start_tone:
        move    #>1,a
        move    a1,y:source_mode
        jsr     ssi_configure
        move    y:ssi_active_base,r0
        jsr     render_tone_period
        jsr     ssi_begin

tone_loop:
        move    y:ssi_refill_base,r0
        jsr     render_tone_period
tone_wait:
        move    y:ssi_active_base,x0
        move    r6,a
        cmp     x0,a
        jeq     tone_handoff
        jclr    #0,x:m_hsr,tone_wait
        movep   x:m_hrx,x1
        move    x1,y:last_command
        move    x1,a
        move    #>$ff0000,y0
        and     y0,a
        move    #>MT32_CMD_STOP_AUDIO,x0
        cmp     x0,a
        jeq     command_stop_audio
        move    #>MT32_CMD_QUERY_TIME,x0
        cmp     x0,a
        jeq     tone_query_time
        move    #>MT32_CMD_QUERY_PERIODS,x0
        cmp     x0,a
        jeq     tone_query_periods
        move    #>MT32_REPLY_ERROR,a
        jsr     send_reply
        jmp     tone_wait

tone_query_time:
        move    y:ssi_frame_count,a
        jsr     send_reply
        jmp     tone_wait

tone_query_periods:
        move    y:ssi_period_count,a
        jsr     send_reply
        jmp     tone_wait

tone_handoff:
        jsr     ssi_perform_handoff
        jmp     tone_loop

; -----------------------------------------------------------------------------
; Source 2: host-supplied periods
; -----------------------------------------------------------------------------

command_start_stream:
        move    #>2,a
        move    a1,y:source_mode
        jsr     ssi_configure
        move    y:ssi_active_base,r0
        jsr     receive_period
        jsr     ssi_begin

; While buffered audio is active, accept refills, queries, and stop.
stream_loop:
        jclr    #0,x:m_hsr,stream_loop
        movep   x:m_hrx,x1
        move    x1,y:last_command
        move    x1,a
        move    #>$ff0000,y0
        and     y0,a
        move    #>MT32_CMD_REFILL_STREAM,x0
        cmp     x0,a
        jeq     command_refill_stream
        move    #>MT32_CMD_STOP_AUDIO,x0
        cmp     x0,a
        jeq     command_stop_audio
        move    #>MT32_CMD_QUERY_TIME,x0
        cmp     x0,a
        jeq     stream_query_time
        move    #>MT32_CMD_QUERY_PERIODS,x0
        cmp     x0,a
        jeq     stream_query_periods
        move    #>MT32_REPLY_ERROR,a
        jsr     send_reply
        jmp     stream_loop

stream_query_time:
        move    y:ssi_frame_count,a
        jsr     send_reply
        jmp     stream_loop

stream_query_periods:
        move    y:ssi_period_count,a
        jsr     send_reply
        jmp     stream_loop

; Take one host period into the buffer the SSI is not playing, acknowledge it
; as soon as it is private DSP memory so the 68030 can start preparing the
; next one, then switch at the next complete stereo boundary. A late host
; leaves the current period untouched and audible: it repeats whole rather
; than tearing.
command_refill_stream:
        move    y:ssi_refill_base,r0
        jsr     receive_period
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        jsr     ssi_wait_boundary
        jsr     ssi_perform_handoff
        jmp     stream_loop

; Park the receiver, tell the host it may release the block, then take one
; complete period. TOS 4.02 Dsp_BlkUnpacked polls TXDE only before the first
; word of a block and writes the rest blind, so a receive loop that starts
; late silently loses a word; the ready token is what keeps the host from
; outrunning this loop.
; in: r0 = destination base
receive_period:
        move    #>MT32_REPLY_BLOCK_READY,a
        jsr     send_reply
        do      #MT32_PERIOD_WORDS,receive_period_done
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,x:(r0)+
receive_period_done:
        rts

; -----------------------------------------------------------------------------
; Codec transport
; -----------------------------------------------------------------------------

ssi_configure:
        movep   #0,x:m_crb
        movep   #$4100,x:m_cra          ; 16-bit words, two-word network frame
        clr     a
        move    a1,y:ssi_frame_count
        move    a1,y:ssi_period_count
        move    #>ssi_buffer_a,a
        move    a1,y:ssi_active_base
        move    #>ssi_buffer_b,a
        move    a1,y:ssi_refill_base
        rts

; Prime the transmitter from the active buffer and enable the network transmit
; interrupt. The modulo pointer then repeats that period until a handoff, so a
; renderer that misses its deadline costs a repeat and never a discontinuity.
ssi_begin:
        move    y:ssi_active_base,r6
        move    #>MT32_PERIOD_MODULO,m6
        nop
        move    x:(r6)+,a
        movep   a1,x:m_tx
        move    #>MT32_PERIOD_FRAMES,a
        move    a1,y:ssi_frame_count
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        movep   #$5a00,x:m_crb          ; network TX + SSI transmit interrupt
        rts

; Spin until the output pointer wraps back to the active buffer base. r6
; equals that base for one whole word period (about 30 us), which this loop
; samples every few instruction cycles.
ssi_wait_boundary:
        move    y:ssi_active_base,x0
ssi_wait_boundary_loop:
        move    r6,a
        cmp     x0,a
        jne     ssi_wait_boundary_loop
        rts

; Swap the buffers at a stereo-frame boundary. Silence the interrupt, let the
; transmitter drain, finish the frame if r6 stopped on a right sample, then
; restart from the freshly prepared block. Scratches a, b, x0.
ssi_perform_handoff:
        movep   #$1a00,x:m_crb
        jclr    #m_tde,x:m_sr,*
        move    r6,a
        jclr    #0,a1,ssi_handoff_even
        movep   x:(r6)+,x:m_tx
        jclr    #m_tde,x:m_sr,*
ssi_handoff_even:
        move    y:ssi_active_base,a
        move    y:ssi_refill_base,b
        move    b1,y:ssi_active_base
        move    a1,y:ssi_refill_base
        move    b1,r6
        move    y:ssi_frame_count,a
        move    #>MT32_PERIOD_FRAMES,x0
        add     x0,a
        move    a1,y:ssi_frame_count
        move    x:(r6)+,a
        movep   a1,x:m_tx
        movep   #$5a00,x:m_crb
        move    y:ssi_period_count,a
        move    #>1,x0
        add     x0,a
        move    a1,y:ssi_period_count
        rts

command_stop_audio:
        movep   #0,x:m_crb
        move    #>-1,m6
        clr     a
        movep   a1,x:m_tx
        move    a1,y:source_mode
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

; SSI transmit-underrun recovery. Reading SSISR followed by writing TX clears
; TUE; this long exception path is not part of normal buffered playback, and
; the retained status word says whether it was ever taken.
ssi_tx_exception:
        movep   x:m_sr,y:ssi_status_snapshot
        movep   x:(r6)+,x:m_tx
        rti

; Send a single 24-bit reply from a1.
send_reply:
        jclr    #1,x:m_hsr,*            ; wait for host transmit data empty
        movep   a1,x:m_htx
        rts

; -----------------------------------------------------------------------------
; Test-tone generator
; -----------------------------------------------------------------------------

mt32_reset:
        clr     a
        move    a1,y:ssi_frame_count
        move    a1,y:ssi_period_count
        move    a1,y:ssi_status_snapshot
        move    a1,y:tone_phase
        move    a1,y:source_mode
        move    #>MT32_TONE_A440_STEP,a
        move    a1,y:tone_step
        move    #>ssi_buffer_a,a
        move    a1,y:ssi_active_base
        move    #>ssi_buffer_b,a
        move    a1,y:ssi_refill_base
        rts

; Fill one whole period with a centred mono sine. The table words are already
; positioned for the 16-bit SSI word length, so the inner loop is one table
; read and two stores.
; in:  r0 = destination base
; out: r0 = one past the period
render_tone_period:
        move    #>tone_sine,r1
        move    #>$00ffff,y1
        move    y:tone_phase,a
        move    y:tone_step,x0
        do      #MT32_PERIOD_FRAMES,render_tone_period_done
        add     x0,a
        and     y1,a1
        move    a1,b
        rep     #8
        lsr     b
        move    b1,n1
        nop
        move    y:(r1+n1),y0
        move    y0,x:(r0)+
        move    y0,x:(r0)+
render_tone_period_done:
        move    a1,y:tone_phase
        rts

; The generated tables are P-memory data, not code: the stage-two loader
; carries P sections only, and generate_dsp_stage2.py fails the build if the
; kernel above ever grows into them. The tone table image sits at the P alias
; of Y:$0800; the LA32 includes carry their own org lines the same way.
        org     p:$800
        include 'tonetabs.inc'          ; DOS assembler requires an 8.3 name
        IF      @DEF(LA32_REVERB_IMAGE)
        include 'la32rvb.inc'
        ELSE
        include 'la32tabs.inc'
        ENDIF

        end
