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
; one synth partial - bit-exact against Munt's integer LA32WaveGenerator with
; amp, pitch and cutoff held constant, as a block-rate kernel would hold them
; - into X:$1000 for the Hatari cycle profiler and the oracle comparison in
; tools/la32_partial.py. The two render loops sit in internal P so their
; fetches never contend with the external table reads; the transport moved to
; external P:$0200 to make room, and its scalar state moved to internal Y
; because internal X now holds the first page of the unlog table. See
; docs/la32-budget.md for the measurements.

        include 'ioequ.inc'
        include 'protocol.inc'

; LA32 spike memory map. tools/la32_partial.py is the source of these
; addresses: it emits the tables as P sections at the alias of each X/Y home
; (Falcon external P = phys, external Y = phys, external X = phys - $4000),
; so the stage-two loader delivers X and Y data it was never taught about.
; The unlog table's first 256 words live in internal X and are copied at boot.
LA32_SQUARE_FWD     equ     $3000   ; X value and Y window tables, 512 each
LA32_SQUARE_ZERO    equ     $3200
LA32_SQUARE_REV     equ     $3400
LA32_SHIFT_Y        equ     $3600   ; 1088 words: 0, 2^15..2^0, then zeros
LA32_RESONANCE_Y    equ     $3c00   ; 1024 words: sine<<2, upper half reversed
LA32_UNLOG_X        equ     $0000   ; 4096 words: interpolateExp(frac)<<8
LA32_UNLOG_IMAGE_P  equ     $4000
LA32_UNLOG_COPY     equ     256
LA32_CONST_WORDS    equ     15
LA32_CONFIG_WORDS   equ     16
LA32_OUTPUT_BASE    equ     $1000
LA32_OUTPUT_WORDS   equ     2*LA32_PROFILE_FRAMES

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

; LA32 partial state, fixed constants and the active configuration, all
; within the 6-bit short-absolute range so the loops load them for free
; beside ALU work. la32_tables_install copies the fixed words from P at boot;
; command_profile copies a configuration block over la_step3 onwards. The
; layout is mirrored by tools/la32_partial.py.
        org     y:$10
la_wp3          ds      1               ; wave position << 3, advanced per frame
la_wphmask      ds      1               ; $7ff800 - first fixed word
la_sh5          ds      1               ; 2^18: mpy by it is a right shift by 5
la_m511         ds      1
la_m7fe0        ds      1               ; R4 bits 5-14: the resonance index
la_sh12         ds      1               ; 2^11: mpy by it is a right shift by 12
la_m4095        ds      1
la_2p14         ds      1
la_pos21        ds      1               ; 2^21: sawtooth cosine offset, wp3 units
la_2p22         ds      1
la_mcos         ds      1               ; $3ff800: cosine index bits
la_rec1         ds      1               ; address of la_half1
la_sh7          ds      1               ; 2^7
la_sgnbit       ds      1               ; $800000
la_shtab        ds      1               ; LA32_SHIFT_Y + 1: the entry for int 0
la_rtab         ds      1               ; LA32_RESONANCE_Y - last fixed word
la_sqlog        ds      1               ; scratch: square log sample
la_rmul         ds      1               ; scratch: resonance sign multiplier
la_rlog         ds      1               ; scratch
la_step3        ds      1               ; configuration: sampleStep << 3
la_k7           ds      1               ; (resonanceWaveLengthFactor >> 4) << 7
la_b3           ds      1               ; start of the negative half, S4 units
la_ampt         ds      1               ; amp>>10 plus the low-cutoff square term
la_rbase        ds      1               ; amp>>10 + resonance amp subtraction + cutoff term - 4096
la_panl9        ds      1               ; pan factors << 9
la_panr9        ds      1
la_saw          ds      1               ; nonzero selects the sawtooth loop
la_half0        ds      4               ; per half: sign base, linear length,
la_half1        ds      4               ;   decay factor << 15, square sign

; The 256-entry test-tone table is external Y data now, delivered by the P
; alias like the LA32 tables, so the boot no longer copies it.
        org     y:$800
tone_sine:
        ds      TONE_TABLE_WORDS

; Two interleaved stereo periods in external X. Both bases are 1024-word
; aligned because the SSI output pointer runs modulo MT32_PERIOD_MODULO, and
; ds keeps them out of the loader image. External X decodes at phys+$4000 on
; the Falcon, clear of the P/Y alias in the lower 16K. The profile spike
; reuses X:$1000-$1fff as its output buffer while no audio runs.
        org     x:$1000
ssi_buffer_a:
        ds      MT32_PERIOD_WORDS

        org     x:$1400
ssi_buffer_b:
        ds      MT32_PERIOD_WORDS

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
;   unlog(v) = interpolateExp(v & 4095) >> (v >> 12): one table gives the
;              first factor, a second, indexed by the integer part, the
;              power of two. Munt clamps every log to 65535, which unlogs to
;              zero; the shift table is zero from integer part 16 upwards and
;              carries a zero guard word for -1, the lowest the resonance
;              can reach, so no clamp is needed for the same result.
;   out = +/-unlog(square) +/- unlog(resonance); L += (out*panL)>>13, R alike
;
; Register contract on entry, set by command_profile: r3 = la_half0,
; r4/r5/r7 = FWD/ZERO/REV square tables, r6 = output, x0 = step, every m
; linear. r1 walks the selected half's record, r2 the selected segment
; table, r0 addresses the resonance sine; the unlog stage borrows r1 and r2.

        org     p:$80

la32_square_run:
        move    y:<la_step3,x0
        do      #LA32_PROFILE_FRAMES,la32_square_done
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
        mac     x1,y0,a                  ; a1 = base + ((R4 >> 5) & 1023)
        move    a1,r0
; square log sample
        move    l:(r2+n2),b              ; b1 = sine<<2 or 0, b0 = window term
        move    y:<la_ampt,a
        add     b,a     y:(r1)+,y1       ; a1 = square log; y1 = decay << 15
        move    a1,y:<la_sqlog
; resonance log sample
        move    y:<la_rbase,a
        mac     x0,y1,a y:(r0),y0        ; a1 = rbase + (R4 * decay) >> 8; y0 = sine<<2
        add     y0,a
        move    b0,x1
        add     x1,a    y:(r1),y1        ; a1 = resonance log; y1 = square sign
; unlog the resonance: b = +/-magnitude * 2^23
        tfr     a,b     y:<la_m4095,x1
        and     x1,b    y:<la_sh12,y0
        move    b1,r1                    ; r1 = fraction = unlog table address
        move    a1,x0
        move    y:<la_shtab,a
        mac     x0,y0,a x:(r1),x0        ; a1 = shift entry address; x0 = unlog(frac)<<8
        move    a1,r2
        move    y:<la_rmul,y0
        move    y:(r2),x1                ; 2^(15 - integer part), or 0
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
        move    y:<la_panl9,y0
        move    y:(r2),x1
        mpy     x0,x1,a
        move    a1,x0
        mac     x0,y1,b                  ; b = (+/-m_sq +/- m_res) * 2^23
; pan into the interleaved accumulation buffer; reload the step for the next frame
        asl     b
        asl     b       y:<la_panr9,y1   ; b1 = 2 * sample
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
        do      #LA32_PROFILE_FRAMES,la32_saw_done
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
        mac     x1,y0,a
        move    a1,r0
        move    l:(r2+n2),b
        move    y:<la_ampt,a
        add     b,a     y:(r1)+,y1
        move    a1,y:<la_sqlog
        move    y:<la_rbase,a
        mac     x0,y1,a y:(r0),y0
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
        move    y:(r2),x1
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
        move    y:<la_panl9,y0
        move    y:(r2),x1
        mpy     x0,x1,a
        move    a1,x0
        mac     x0,y1,b
        asl     b
        asl     b       y:<la_panr9,y1
        move    b1,x0
        move    x:(r6),a
        mac     x0,y0,a
        move    a1,x:(r6)+
        move    x:(r6),a
        mac     x0,y1,a y:<la_step3,x0
        move    a1,x:(r6)+
la32_saw_done:
        rts

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
; LA32 profile spike: MT32_CMD_PROFILE_PARTIAL
; -----------------------------------------------------------------------------

; Install the selected configuration, clear the output buffer, render, fold
; the buffer into a checksum and reply with it. The render loops carry the
; profiler's start and end labels; everything here is outside the bracket.
command_profile:
        move    y:last_command,a
        move    #>$0000ff,x0
        and     x0,a
        move    a1,b
        rep     #4
        asl     b                       ; configuration index * 16
        move    #>la32_cfg_image,x0
        add     x0,b
        move    b1,r0
        move    #<la_step3,r1
        do      #LA32_CONFIG_WORDS,command_profile_installed
        move    p:(r0)+,x0
        move    x0,y:(r1)+
command_profile_installed:
        ; the loop advances before it renders, so start one step early and
        ; the first frame is Munt's position zero
        clr     a
        move    y:<la_step3,x0
        sub     x0,a
        move    a1,y:<la_wp3
        move    #>LA32_OUTPUT_BASE,r6
        move    #>LA32_OUTPUT_WORDS,x0
        clr     a
        do      x0,command_profile_cleared
        move    a1,x:(r6)+
command_profile_cleared:
        move    #>-1,m0
        move    #>-1,m1
        move    #>-1,m2
        move    #>-1,m3
        move    #>-1,m5
        move    #>-1,m6
        move    #>-1,m7
        move    #<la_half0,r3
        move    #>LA32_SQUARE_FWD,r4
        move    #>LA32_SQUARE_ZERO,r5
        move    #>LA32_SQUARE_REV,r7
        move    #>LA32_OUTPUT_BASE,r6
        move    y:<la_saw,a
        tst     a
        jne     command_profile_saw
        jsr     la32_square_run
        jmp     command_profile_fold
command_profile_saw:
        jsr     la32_saw_run
command_profile_fold:
        move    #>LA32_OUTPUT_BASE,r6
        move    #>LA32_OUTPUT_WORDS,x0
        clr     a
        do      x0,command_profile_folded
        move    x:(r6)+,x1
        asl     a
        add     x1,a
command_profile_folded:
        jsr     send_reply
        jmp     command_loop

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
        rts

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
; of Y:$0800; la32tabs.inc carries its own org lines the same way.
        org     p:$800
        include 'tonetabs.inc'          ; DOS assembler requires an 8.3 name
        include 'la32tabs.inc'

        end
