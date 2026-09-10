; 68030 PCM partial spike.
;
; The MT-32's PCM partials cannot run on the Falcon DSP, whose SRAM cannot
; hold the PCM ROM, so the plan renders them on the 68030 and streams the mix
; to the DSP each period (docs/architecture.md). This file measures what one
; such partial costs: two kernels render Munt's integer PCM model into a
; stereo buffer of zero-padded 24-bit words, the format the paced host-port
; blast sends, with amp, pitch and pan held constant as a block-rate host
; would hold them between control updates.
;
; The exact kernel reproduces LA32WaveGenerator::generateNextPCMWaveLogSamples
; and LA32IntPartialPair::unlogAndMixWGOutput word for word: each of the two
; neighbouring ROM words becomes a log value plus the amp term, clamped,
; and leaves the log domain through a signed 131,072-word unlog table
; indexed by sign and log; the pair is interpolated in the linear domain by
; the seven-bit fraction of the position; the pan factors mix the result.
; The perceptual kernel reads the same waves converted to linear samples
; once, interpolates, and applies amp and pan as one multiply per channel.
;
; See docs/la32-budget.md for the measurement and tools/pcm_partial.py for
; the tables, the runs and the comparison against Munt.

        include "protocol.i"

        global  pcm_prepare
        global  pcm_render
        global  pcm_position
        global  pcm_ended
        global  pcm_output_header
        global  pcm_output
        global  pcm_scratch
        global  pcm_cfg_image

; Configuration record, tools/pcm_partial.py config_longs.
PCM_CFG_WAVE    equ     0
PCM_CFG_LENGTH  equ     4
PCM_CFG_LOOPED  equ     8
PCM_CFG_STEP    equ     12
PCM_CFG_AMPT    equ     16
PCM_CFG_PANL    equ     20
PCM_CFG_PANR    equ     24
PCM_CFG_KERNEL  equ     28
PCM_CFG_GAINL   equ     32
PCM_CFG_GAINR   equ     36

PCM_WAVE_LOOP_SAMPLES equ 2048
PCM_WAVE_SHOT_SAMPLES equ 4096
PCM_UNLOG_ENTRIES equ   65536

        text

; -----------------------------------------------------------------------------
; Tables a production host would build once from the PCM ROM
; -----------------------------------------------------------------------------

; The signed unlog table: u[sign<<16 | log] = +/-(interpolateExp(log & 4095)
; >> (log >> 12)), so one indexed read does what LA32Utilites::unlog does
; with a shift and a sign test. Then each wave in linear form for the
; perceptual kernel, read through that same table with no amp term.
pcm_prepare:
        movem.l d0-d2/a0-a3,-(sp)
        lea     pcm_unlog_image,a0
        lea     pcm_unlog_signed,a1
        lea     2*PCM_UNLOG_ENTRIES(a1),a2
        moveq   #0,d1                   ; integer part of the log
pcm_prepare_int:
        movea.l a0,a3
        move.w  #4095,d2
pcm_prepare_frac:
        move.w  (a3)+,d0
        lsr.w   d1,d0
        move.w  d0,(a1)+
        neg.w   d0
        move.w  d0,(a2)+
        dbra    d2,pcm_prepare_frac
        addq.w  #1,d1
        cmpi.w  #16,d1
        blo.s   pcm_prepare_int

        lea     pcm_wave_loop_image,a0
        lea     pcm_wave_loop_linear,a1
        move.w  #PCM_WAVE_LOOP_SAMPLES-1,d2
        bsr.s   pcm_linearize
        lea     pcm_wave_shot_image,a0
        lea     pcm_wave_shot_linear,a1
        move.w  #PCM_WAVE_SHOT_SAMPLES-1,d2
        bsr.s   pcm_linearize
        movem.l (sp)+,d0-d2/a0-a3
        rts

; in: a0 = converted ROM words, a1 = linear destination, d2.w = count - 1
pcm_linearize:
        lea     pcm_unlog_signed,a2
pcm_linearize_loop:
        moveq   #0,d0
        move.w  (a0)+,d0
        add.l   d0,d0                   ; sign to bit 16, half-log doubled
        move.w  (a2,d0.l*2),(a1)+
        dbra    d2,pcm_linearize_loop
        rts

; -----------------------------------------------------------------------------
; Render entry
; -----------------------------------------------------------------------------

; Render frames of the configured partial, continuing from pcm_position.
; in:  a0 = configuration record, a1 = output (two longs per frame),
;      d0.l = frames
; Register use inside the kernels:
;   d0 position (8 fractional bits)   d1 step        d2 amp term (exact)
;   d3 length << 8                    d4 scratch     d5 = 13, the pan shift
;   d6 first sample                   d7 second sample, then the result
;   a0 wave                           a1 signed unlog table (exact)
;   a2 output                         a3 length      a4 pan record
;   a5 end of output                  a6 configuration
pcm_render:
        movem.l d1-d7/a2-a6,-(sp)
        movea.l a0,a6
        movea.l a1,a2
        lsl.l   #3,d0
        lea     (a1,d0.l),a5
        tst.l   pcm_ended
        bne     pcm_fill_silence_done
        move.l  pcm_position,d0
        move.l  PCM_CFG_STEP(a6),d1
        move.l  PCM_CFG_LENGTH(a6),d3
        movea.l d3,a3
        lsl.l   #8,d3
        moveq   #13,d5
        lea     pcm_pan_record,a4
        move.l  PCM_CFG_PANL(a6),d4
        move.w  d4,(a4)
        move.l  PCM_CFG_PANR(a6),d4
        move.w  d4,2(a4)
        move.l  PCM_CFG_LOOPED(a6),d4
        move.w  d4,4(a4)
        tst.l   PCM_CFG_WAVE(a6)
        bne.s   pcm_render_shot
        lea     pcm_wave_loop_image,a0
        lea     pcm_wave_loop_linear,a1
        bra.s   pcm_render_wave_known
pcm_render_shot:
        lea     pcm_wave_shot_image,a0
        lea     pcm_wave_shot_linear,a1
pcm_render_wave_known:
        move.l  PCM_CFG_KERNEL(a6),d4
        bne.s   pcm_render_linear
        lea     pcm_unlog_signed,a1
        move.w  PCM_CFG_AMPT+2(a6),d2
        bsr.s   pcm_exact
        bra.s   pcm_render_done
pcm_render_linear:
        movea.l a1,a0
        move.l  PCM_CFG_GAINL(a6),d0
        move.w  d0,(a4)
        move.l  PCM_CFG_GAINR(a6),d0
        move.w  d0,2(a4)
        move.l  pcm_position,d0
        subq.l  #1,d4
        bne.s   pcm_render_mono
        bsr     pcm_perceptual
        bra.s   pcm_render_done
pcm_render_mono:
        bsr     pcm_mono
pcm_render_done:
        move.l  d0,pcm_position
        movem.l (sp)+,d1-d7/a2-a6
        rts

; -----------------------------------------------------------------------------
; Exact kernel
; -----------------------------------------------------------------------------

pcm_exact:
        move.l  d0,d4
        lsr.l   #8,d4                   ; sample index
        moveq   #0,d6
        move.w  (a0,d4.l*2),d6          ; first word: sign, half-log
        addq.l  #1,d4
        cmp.l   a3,d4
        blo.s   pcm_exact_second
        moveq   #0,d4                   ; past the end: wrap if looped,
        tst.w   4(a4)                   ; otherwise the second is silence
        bne.s   pcm_exact_second
        moveq   #0,d7
        bra.s   pcm_exact_first
pcm_exact_second:
        moveq   #0,d7
        move.w  (a0,d4.l*2),d7
        add.l   d7,d7                   ; sign to bit 16, log = half-log << 1
        add.w   d2,d7                   ; + amp term, clamped at 65535
        bcc.s   pcm_exact_second_ok
        or.w    #$ffff,d7
pcm_exact_second_ok:
        move.w  (a1,d7.l*2),d7          ; signed unlog
pcm_exact_first:
        add.l   d6,d6
        add.w   d2,d6
        bcc.s   pcm_exact_first_ok
        or.w    #$ffff,d6
pcm_exact_first_ok:
        move.w  (a1,d6.l*2),d6
        sub.w   d6,d7                   ; second - first
        moveq   #0,d4
        move.b  d0,d4
        lsr.b   #1,d4                   ; interpolation factor, 7 bits
        muls.w  d4,d7
        asr.l   #7,d7
        add.w   d6,d7                   ; the partial's 16-bit sample
        add.l   d1,d0                   ; advance; Munt silences the frame
        cmp.l   d3,d0                   ; whose advance ends a one-shot wave
        blo.s   pcm_exact_store
        tst.w   4(a4)
        beq.s   pcm_fill_silence
        sub.l   d3,d0
pcm_exact_store:
        move.w  d7,d4
        muls.w  (a4),d4                 ; * left pan factor
        asr.l   d5,d4                   ; >> 13
        move.l  d4,(a2)+
        muls.w  2(a4),d7                ; * right pan factor
        asr.l   d5,d7
        move.l  d7,(a2)+
        cmpa.l  a5,a2
        bne     pcm_exact
        rts

; A one-shot wave ended: this frame and every later one is silence.
pcm_fill_silence:
        move.l  #1,pcm_ended
pcm_fill_silence_done:
        cmpa.l  a5,a2
        beq.s   pcm_fill_silence_end
        clr.l   (a2)+
        bra.s   pcm_fill_silence_done
pcm_fill_silence_end:
        rts

; -----------------------------------------------------------------------------
; Perceptual kernel
; -----------------------------------------------------------------------------

; a0 = the wave in linear form, a4 = gain-times-pan factors and the looped
; flag; amp and pan are one Q13 multiply per channel after the interpolation.
pcm_perceptual:
        move.l  d0,d4
        lsr.l   #8,d4
        move.w  (a0,d4.l*2),d6
        addq.l  #1,d4
        cmp.l   a3,d4
        blo.s   pcm_perceptual_second
        moveq   #0,d4
        tst.w   4(a4)
        bne.s   pcm_perceptual_second
        moveq   #0,d7
        bra.s   pcm_perceptual_mix
pcm_perceptual_second:
        move.w  (a0,d4.l*2),d7
pcm_perceptual_mix:
        sub.w   d6,d7
        moveq   #0,d4
        move.b  d0,d4
        lsr.b   #1,d4
        muls.w  d4,d7
        asr.l   #7,d7
        add.w   d6,d7
        add.l   d1,d0
        cmp.l   d3,d0
        blo.s   pcm_perceptual_store
        tst.w   4(a4)
        beq.s   pcm_fill_silence
        sub.l   d3,d0
pcm_perceptual_store:
        move.w  d7,d4
        muls.w  (a4),d4                 ; * (gain * left pan)
        asr.l   d5,d4
        move.l  d4,(a2)+
        muls.w  2(a4),d7
        asr.l   d5,d7
        move.l  d7,(a2)+
        cmpa.l  a5,a2
        bne     pcm_perceptual
        rts

; -----------------------------------------------------------------------------
; Mono kernel
; -----------------------------------------------------------------------------

; The perceptual kernel without the pan: one gain multiply and one word per
; frame, the partial as it would leave for a DSP that pans and mixes it.
; The word lands in the frame's left slot; the right slot is left alone.
pcm_mono:
        move.l  d0,d4
        lsr.l   #8,d4
        move.w  (a0,d4.l*2),d6
        addq.l  #1,d4
        cmp.l   a3,d4
        blo.s   pcm_mono_second
        moveq   #0,d4
        tst.w   4(a4)
        bne.s   pcm_mono_second
        moveq   #0,d7
        bra.s   pcm_mono_mix
pcm_mono_second:
        move.w  (a0,d4.l*2),d7
pcm_mono_mix:
        sub.w   d6,d7
        moveq   #0,d4
        move.b  d0,d4
        lsr.b   #1,d4
        muls.w  d4,d7
        asr.l   #7,d7
        add.w   d6,d7
        add.l   d1,d0
        cmp.l   d3,d0
        blo.s   pcm_mono_store
        tst.w   4(a4)
        beq     pcm_fill_silence
        sub.l   d3,d0
pcm_mono_store:
        muls.w  (a4),d7                 ; * gain
        asr.l   d5,d7
        move.l  d7,(a2)
        addq.l  #8,a2
        cmpa.l  a5,a2
        bne     pcm_mono
        rts

; -----------------------------------------------------------------------------
; Data and state
; -----------------------------------------------------------------------------

        data
        include "pcmtabs.i"

        bss

pcm_unlog_signed:
        ds.w    2*PCM_UNLOG_ENTRIES
pcm_wave_loop_linear:
        ds.w    PCM_WAVE_LOOP_SAMPLES
pcm_wave_shot_linear:
        ds.w    PCM_WAVE_SHOT_SAMPLES
pcm_pan_record:
        ds.w    4
pcm_position:
        ds.l    1
pcm_ended:
        ds.l    1

; The file the host writes for tools/pcm_partial.py: the header, then the
; checked frames as left and right longs.
pcm_output_header:
        ds.b    20
pcm_output:
        ds.l    2*PCM_PROFILE_FRAMES
; One period rendered over and over inside the profile window.
pcm_scratch:
        ds.l    2*MT32_PERIOD_FRAMES

        end
