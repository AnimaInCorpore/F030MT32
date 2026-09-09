        include "xbios.i"
        include "verbose.i"
        include "protocol.i"

        global  start
        ifd     VERBOSE_BOOT
        global  vb_hex
        global  vb_string
        endc

DSP_X_WORDS     equ     8192
DSP_Y_WORDS     equ     8192
DSP_ABILITY     equ     3

SOUND_STEREO16  equ     1
SOUND_DSP_XMIT  equ     1
SOUND_DAC       equ     8
SOUND_CLK25M    equ     0
SOUND_CLK33K    equ     2               ; prescale 2: 25.175 MHz / 256 / 3
SOUND_NO_SHAKE  equ     1
SOUND_LTATTEN   equ     0
SOUND_RTATTEN   equ     1
SOUND_ADDERIN   equ     4
SOUND_INQUIRE   equ     -1
SOUND_FULL      equ     0
SOUND_MATRIXIN  equ     2               ; adder takes the matrix, not the A/D
SOUND_MONPAIR0  equ     0               ; DAC monitors frame slots 0 and 1
SOUND_DMA_STOP  equ     0
SNDSTAT_RESET   equ     1

MODE_SELFTEST   equ     0
MODE_TONE       equ     1
MODE_STREAM     equ     2

; Self-test durations. Long enough that a stalled SSI clock is unmistakable in
; the frame counter, short enough for a non-interactive emulator run.
SELFTEST_TONE_VBLS equ      40
SELFTEST_STREAM_PERIODS equ 32

; The host-supplied source is a square wave one octave below the DSP tone, so
; the two paths are told apart by ear as well as by the trace. The samples are
; +/- 4096 of 32767, left-justified in the 24-bit word exactly like the DSP
; table; see tools/generate_tone_table.py.
HOST_SQUARE_STEP equ    440             ; 220.08 Hz
HOST_SQUARE_HIGH equ    $100000
HOST_SQUARE_LOW  equ    $f00000

        text

start:
        move.l  4(sp),mt32_basepage
        Cconws  banner

        movea.l 4(sp),a0                ; TOS basepage at process entry
        lea     $80(a0),a0              ; length-prefixed command tail
        bsr     parse_tail
        move.l  d0,run_mode

        VB      vb_txt_reserve
        Dsp_Reserve #DSP_X_WORDS,#DSP_Y_WORDS
        VBH
        tst.l   d0
        bmi     reserve_failed

        ; XBIOS can boot at most 512 contiguous internal-P words. Install the
        ; embedded loader there, then stream the complete sparse program as
        ; unpacked 24-bit words. The loader acknowledges only after every
        ; section is resident and immediately enters the final reset vector.
        VBV     vb_txt_bootwords,#DSP_BOOT_WORDS
        VB      vb_txt_execboot
        Dsp_ExecBoot dsp_bootstrap_image,#DSP_BOOT_WORDS,#DSP_ABILITY
        VBH
        VBV     vb_txt_stagewords,#DSP_STAGE2_TRANSFER_WORDS
        clr.l   dsp_stage2_reply
        VB      vb_txt_stage2
        Dsp_BlkUnpacked dsp_program_image,#DSP_STAGE2_TRANSFER_WORDS,dsp_stage2_reply,#1
        move.l  dsp_stage2_reply,d0
        VBH
        cmp.l   #DSP_STAGE2_REPLY_OK,d0
        bne     load_failed

        VB      vb_txt_ping
        move.l  #MT32_CMD_PING,d0
        bsr     dsp_exchange
        VBH
        cmp.l   #MT32_REPLY_HELLO,d0
        bne     protocol_failed
        Cconws  dsp_ready_text

        bsr     sound_open
        tst.l   d0
        bne     sound_failed

        move.l  run_mode,d0
        cmpi.l  #MODE_STREAM,d0
        beq     dispatch_stream
        cmpi.l  #MODE_TONE,d0
        beq     dispatch_tone

; The default run is non-interactive so an emulator gate can score it: play
; the DSP tone, prove the codec frame counter advanced, then hand the same
; transport a host-supplied source and prove the period handoffs happened.
dispatch_selftest:
        bsr     run_tone_selftest
        tst.l   d0
        bne     audio_failed
        bsr     run_stream_selftest
        tst.l   d0
        bne     audio_failed
        bra     clean_exit

dispatch_tone:
        bsr     run_tone_interactive
        tst.l   d0
        bne     audio_failed
        bra     clean_exit

dispatch_stream:
        bsr     run_stream_interactive
        tst.l   d0
        bne     audio_failed

clean_exit:
        bsr     sound_close
        Cconws  done_text
        Pterm0

; -----------------------------------------------------------------------------
; Sources
; -----------------------------------------------------------------------------

; Start the DSP tone, let it run, and report how far the codec got. A frozen
; or absent SSI clock leaves both counters at their starting values, which is
; the one failure this program can diagnose without any host data path.
; out: d0.l = 0 on success
run_tone_selftest:
        move.l  #MT32_CMD_SET_TONE+MT32_TONE_A440_STEP,d0
        bsr     dsp_exchange
        cmp.l   #MT32_REPLY_OK,d0
        bne.s   run_tone_selftest_failed

        move.l  #MT32_CMD_START_TONE,d0
        bsr     dsp_exchange
        cmp.l   #MT32_REPLY_OK,d0
        bne.s   run_tone_selftest_failed

        move.w  #SELFTEST_TONE_VBLS,d7
        bsr     wait_vbls

        move.l  #MT32_CMD_QUERY_TIME,d0
        bsr     dsp_exchange
        lea     txt_tone_frames,a0
        bsr     report_value
        move.l  #MT32_CMD_QUERY_PERIODS,d0
        bsr     dsp_exchange
        lea     txt_tone_periods,a0
        bsr     report_value

        bsr     stop_audio
        moveq   #0,d0
        rts
run_tone_selftest_failed:
        moveq   #-1,d0
        rts

; out: d0.l = 0 on success
run_tone_interactive:
        move.l  #MT32_CMD_START_TONE,d0
        bsr     dsp_exchange
        cmp.l   #MT32_REPLY_OK,d0
        bne.s   run_tone_interactive_failed
        Cconws  hold_text
        bsr     hold_until_key
        bsr     stop_audio
        moveq   #0,d0
        rts
run_tone_interactive_failed:
        moveq   #-1,d0
        rts

; Feed the same transport from the 68030. Every refill blocks until the DSP
; has taken the block and swapped it in at a period boundary, so the loop
; paces itself on the codec; the pipelined producer that keeps a payload
; parked ahead of the handoff is future work (see docs/architecture.md).
; out: d0.l = 0 on success
run_stream_selftest:
        bsr     start_stream
        tst.l   d0
        bne.s   run_stream_selftest_failed

        move.w  #SELFTEST_STREAM_PERIODS,d6
run_stream_selftest_loop:
        bsr     refill_stream
        tst.l   d0
        bne.s   run_stream_selftest_failed
        subq.w  #1,d6
        bne.s   run_stream_selftest_loop

        move.l  #MT32_CMD_QUERY_PERIODS,d0
        bsr     dsp_exchange
        lea     txt_stream_periods,a0
        bsr     report_value

        bsr     stop_audio
        moveq   #0,d0
        rts
run_stream_selftest_failed:
        moveq   #-1,d0
        rts

; out: d0.l = 0 on success
run_stream_interactive:
        bsr     start_stream
        tst.l   d0
        bne.s   run_stream_interactive_failed
        Cconws  hold_text
run_stream_interactive_loop:
        bsr     refill_stream
        tst.l   d0
        bne.s   run_stream_interactive_failed
        Cconis
        tst.w   d0
        beq.s   run_stream_interactive_loop
        Cconin
        bsr     stop_audio
        moveq   #0,d0
        rts
run_stream_interactive_failed:
        moveq   #-1,d0
        rts

; out: d0.l = 0 on success
start_stream:
        bsr     build_period
        move.l  #MT32_CMD_START_STREAM,d0
        lea     period_buffer,a3
        move.l  #MT32_PERIOD_WORDS,d3
        bsr     dsp_send_block
        cmp.l   #MT32_REPLY_OK,d0
        bne.s   start_stream_failed
        moveq   #0,d0
        rts
start_stream_failed:
        moveq   #-1,d0
        rts

; out: d0.l = 0 on success
refill_stream:
        bsr     build_period
        move.l  #MT32_CMD_REFILL_STREAM,d0
        lea     period_buffer,a3
        move.l  #MT32_PERIOD_WORDS,d3
        bsr     dsp_send_block
        cmp.l   #MT32_REPLY_OK,d0
        bne.s   refill_stream_failed
        moveq   #0,d0
        rts
refill_stream_failed:
        moveq   #-1,d0
        rts

; Fill period_buffer with one period of a centred mono square wave. Each slot
; is a zero-padded 24-bit DSP word, ready for the paced host-port blast.
build_period:
        lea     period_buffer,a0
        move.l  host_phase,d1
        move.w  #MT32_PERIOD_FRAMES-1,d2
build_period_frame:
        addi.l  #HOST_SQUARE_STEP,d1
        andi.l  #$0000ffff,d1
        btst    #15,d1
        bne.s   build_period_low
        move.l  #HOST_SQUARE_HIGH,d0
        bra.s   build_period_store
build_period_low:
        move.l  #HOST_SQUARE_LOW,d0
build_period_store:
        move.l  d0,(a0)+
        move.l  d0,(a0)+
        dbra    d2,build_period_frame
        move.l  d1,host_phase
        rts

stop_audio:
        move.l  #MT32_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        rts

; -----------------------------------------------------------------------------
; Falcon sound matrix
; -----------------------------------------------------------------------------

; out: d0.l = 0 on success
sound_open:
        VB      vb_txt_locksnd
        Locksnd
        VBH
        cmpi.l  #1,d0
        bne     sound_open_failed
        move.b  #1,sound_owned

        ; Falcon codec attenuation survives across programs. Preserve it, then
        ; explicitly unmute both DAC channels for this session.
        Soundcmd #SOUND_LTATTEN,#SOUND_INQUIRE
        move.w  d0,old_left_atten
        Soundcmd #SOUND_RTATTEN,#SOUND_INQUIRE
        move.w  d0,old_right_atten

        ; The rest of the matrix also survives across programs, and TOS does
        ; not reset it for a new Devconnect. Stop any inherited DMA playback
        ; that would contend for the same DAC, reinitialize the converters,
        ; and pin every route this program depends on instead of inheriting
        ; it. None of this can be exercised under Hatari, which starts clean.
        VB      vb_txt_sndreset
        Buffoper #SOUND_DMA_STOP
        Sndstatus #SNDSTAT_RESET
        Soundcmd #SOUND_LTATTEN,#SOUND_FULL
        Soundcmd #SOUND_RTATTEN,#SOUND_FULL
        Soundcmd #SOUND_ADDERIN,#SOUND_MATRIXIN
        Setmode #SOUND_STEREO16
        Settracks #0,#0
        ; The DSP fills frame slots 0 and 1; a stale monitor pair points the
        ; DAC at slots this program never writes.
        Setmontracks #SOUND_MONPAIR0
        VB      vb_txt_tristate
        Dsptristate #1,#0
        VB      vb_txt_devconnect
        Devconnect #SOUND_DSP_XMIT,#SOUND_DAC,#SOUND_CLK25M,#SOUND_CLK33K,#SOUND_NO_SHAKE
        moveq   #0,d0
        rts
sound_open_failed:
        moveq   #-1,d0
        rts

sound_close:
        tst.b   sound_owned
        beq.s   sound_close_done
        Dsptristate #0,#0
        Soundcmd #SOUND_LTATTEN,old_left_atten
        Soundcmd #SOUND_RTATTEN,old_right_atten
        Unlocksnd
        clr.b   sound_owned
sound_close_done:
        rts

; -----------------------------------------------------------------------------
; Command tail, console helpers, failure exits
; -----------------------------------------------------------------------------

; Only the first letter of the tail selects a mode, so TONE, tone and T are all
; accepted and anything else falls back to the scored self-test.
; in:  a0 = length-prefixed command tail
; out: d0.l = MODE_*
parse_tail:
        moveq   #0,d1
        move.b  (a0)+,d1                ; tail length
        beq.s   parse_tail_default
parse_tail_skip:
        tst.b   d1
        beq.s   parse_tail_default
        move.b  (a0)+,d0
        subq.b  #1,d1
        cmpi.b  #' ',d0
        beq.s   parse_tail_skip
        cmpi.b  #9,d0
        beq.s   parse_tail_skip
        andi.b  #$df,d0                 ; fold to upper case
        cmpi.b  #'T',d0
        beq.s   parse_tail_tone
        cmpi.b  #'S',d0
        beq.s   parse_tail_stream
parse_tail_default:
        moveq   #MODE_SELFTEST,d0
        rts
parse_tail_tone:
        moveq   #MODE_TONE,d0
        rts
parse_tail_stream:
        moveq   #MODE_STREAM,d0
        rts

; Wait d7.w vertical blanks. XBIOS preserves d3-d7, so the counter survives.
; Clobbers d0-d2/a0-a2.
wait_vbls:
        tst.w   d7
        beq.s   wait_vbls_done
wait_vbls_loop:
        Vsync
        subq.w  #1,d7
        bne.s   wait_vbls_loop
wait_vbls_done:
        rts

hold_until_key:
        Cconis
        tst.w   d0
        bne.s   hold_until_key_done
        Vsync
        bra.s   hold_until_key
hold_until_key_done:
        Cconin
        rts

; Print "label $xxxxxx" and a newline. The same lines go to the console on a
; real Falcon and into the emulator's screen capture, so one run is reportable
; either way.
; in: a0 = NUL-terminated label, d0.l = value
report_value:
        movem.l d0-d2/a0-a2,-(sp)
        Cconws  (a0)
        movem.l (sp),d0-d2/a0-a2
        lea     hex_buffer,a1
        move.b  #'$',(a1)+
        moveq   #5,d1                   ; six digits: one 24-bit DSP word
report_value_digit:
        rol.l   #4,d0
        move.b  d0,d2
        andi.b  #$0f,d2
        addi.b  #'0',d2
        cmpi.b  #'9',d2
        bls.s   report_value_store
        addi.b  #7,d2
report_value_store:
        move.b  d2,(a1)+
        dbra    d1,report_value_digit
        move.b  #13,(a1)+
        move.b  #10,(a1)+
        clr.b   (a1)
        Cconws  hex_buffer
        movem.l (sp)+,d0-d2/a0-a2
        rts

reserve_failed:
        Cconws  reserve_error_text
        bra.s   fail_exit
load_failed:
        Cconws  load_error_text
        bra.s   fail_exit
protocol_failed:
        Cconws  protocol_error_text
        bra.s   fail_exit
sound_failed:
        Cconws  sound_error_text
        bra.s   fail_exit
audio_failed:
        Cconws  audio_error_text
fail_exit:
        bsr     sound_close
        move.w  #1,-(sp)
        move.w  #76,-(sp)               ; Pterm with a failing status
        trap    #1

; -----------------------------------------------------------------------------
; Verbose bring-up helpers
; -----------------------------------------------------------------------------

        ifd     VERBOSE_BOOT
; Print d0.l as eight hex digits followed by CRLF, preserving every register.
vb_hex:
        movem.l d0-d2/a0-a2,-(sp)
        lea     vb_hex_buffer,a1
        moveq   #7,d1
vb_hex_digit:
        rol.l   #4,d0
        move.b  d0,d2
        andi.b  #$0f,d2
        addi.b  #'0',d2
        cmpi.b  #'9',d2
        bls.s   vb_hex_store
        addi.b  #7,d2
vb_hex_store:
        move.b  d2,(a1)+
        dbra    d1,vb_hex_digit
        move.b  #13,(a1)+
        move.b  #10,(a1)+
        clr.b   (a1)
        Cconws  vb_hex_buffer
        movem.l (sp)+,d0-d2/a0-a2
        rts

; Print the NUL-terminated string at a0, then CRLF.
vb_string:
        movem.l d0-d2/a0-a2,-(sp)
        Cconws  (a0)
        Cconws  vb_crlf
        movem.l (sp)+,d0-d2/a0-a2
        rts

        data
vb_crlf:            dc.b 13,10,0
vb_txt_reserve:     dc.b 'Dsp_Reserve      ',0
vb_txt_bootwords:   dc.b 'boot words       ',0
vb_txt_execboot:    dc.b 'Dsp_ExecBoot     ',0
vb_txt_stagewords:  dc.b 'stage2 words     ',0
vb_txt_stage2:      dc.b 'stage2 upload    ',0
vb_txt_ping:        dc.b 'PING             ',0
vb_txt_locksnd:     dc.b 'Locksnd          ',0
vb_txt_sndreset:    dc.b 'Buffoper/Sndstatus reset',13,10,0
vb_txt_tristate:    dc.b 'Dsptristate',13,10,0
vb_txt_devconnect:  dc.b 'Devconnect',13,10,0
        even
        endc

; -----------------------------------------------------------------------------
; Text
; -----------------------------------------------------------------------------

        data

banner:
        dc.b    'F030MT32 scaffold - Roland MT-32 on the Falcon DSP',13,10
        dc.b    'no LA32 synthesis yet; this validates boot and transport',13,10,0
dsp_ready_text:
        dc.b    'DSP resident, protocol v1',13,10,0
hold_text:
        dc.b    'playing - press a key to stop',13,10,0
done_text:
        dc.b    'done',13,10,0
txt_tone_frames:
        dc.b    'tone codec frames  ',0
txt_tone_periods:
        dc.b    'tone periods       ',0
txt_stream_periods:
        dc.b    'stream periods     ',0
reserve_error_text:
        dc.b    'Dsp_Reserve failed',13,10,0
load_error_text:
        dc.b    'DSP program upload failed',13,10,0
protocol_error_text:
        dc.b    'DSP protocol handshake failed',13,10,0
sound_error_text:
        dc.b    'sound system is locked by another program',13,10,0
audio_error_text:
        dc.b    'audio transport failed',13,10,0
        even

; The generated DSP image closes the data section, as in F030MXDRV. A TOS
; executable starts at the first byte of its text segment, so the image must
; never precede start: - included at the top of this file it assembled into
; text ahead of the entry point and TOS executed DSP words as 68030 code.
        include "dsp_stage2_image.i"

        bss

mt32_basepage:
        ds.l    1
run_mode:
        ds.l    1
dsp_stage2_reply:
        ds.l    1
host_phase:
        ds.l    1
old_left_atten:
        ds.w    1
old_right_atten:
        ds.w    1
sound_owned:
        ds.b    1
        even
hex_buffer:
        ds.b    16
        ifd     VERBOSE_BOOT
vb_hex_buffer:
        ds.b    16
        endc
        even

; One period of zero-padded 24-bit DSP words. BSS, not initialized data: the
; TOS loader clears the TPA and every slot is rewritten before it is sent.
period_buffer:
        ds.l    MT32_PERIOD_WORDS

        end
