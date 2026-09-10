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
MODE_PROFILE    equ     3
MODE_PCM        equ     4
MODE_CONTROL    equ     5

PCM_CFG_BYTES   equ     40              ; tools/pcm_partial.py config_longs
PCM_OUTPUT_BYTES equ    20+8*PCM_PROFILE_FRAMES

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
        cmpi.l  #MODE_SELFTEST,d0
        bne.s   start_mode_known
        bsr     read_profile_cfg        ; a PROFILE.CFG beside the program
start_mode_known:                       ; selects the LA32 profile spike
        move.l  d0,run_mode

        ; Two DSP images share one bootstrap loader: the partial spike's,
        ; and the reverb spike's for the runs from LA32_PROFILE_FIRST_REVERB.
        lea     dsp_program_image,a0
        move.l  a0,dsp_image_ptr
        move.l  #DSP_STAGE2_TRANSFER_WORDS,dsp_image_words
        cmpi.l  #MODE_PROFILE,d0
        bne.s   start_image_known
        cmpi.l  #LA32_PROFILE_FIRST_REVERB,profile_cfg
        blo.s   start_image_known
        lea     dsp_reverb_program_image,a0
        move.l  a0,dsp_image_ptr
        move.l  #DSP_REVERB_STAGE2_TRANSFER_WORDS,dsp_image_words
start_image_known:

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
        VBV     vb_txt_stagewords,dsp_image_words
        clr.l   dsp_stage2_reply
        VB      vb_txt_stage2
        ; Dsp_BlkUnpacked with the selected image; the macro takes only
        ; immediate operands.
        move.l  #1,-(sp)
        pea     dsp_stage2_reply
        move.l  dsp_image_words,-(sp)
        move.l  dsp_image_ptr,-(sp)
        move.w  #98,-(sp)
        trap    #14
        lea     18(sp),sp
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

        ; The profile spikes never touch the codec, so they run before the
        ; sound matrix is claimed and exit without restoring anything.
        move.l  run_mode,d0
        cmpi.l  #MODE_PROFILE,d0
        beq     dispatch_profile
        cmpi.l  #MODE_PCM,d0
        beq     dispatch_pcm
        cmpi.l  #MODE_CONTROL,d0
        beq     dispatch_control

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

dispatch_profile:
        bsr     run_profile
        tst.l   d0
        bne     profile_failed
        Cconws  done_text
        Pterm0

dispatch_pcm:
        bsr     run_pcm
        tst.l   d0
        bne     pcm_failed
        Cconws  done_text
        Pterm0

dispatch_control:
        bsr     run_control
        tst.l   d0
        bne     control_failed
        Cconws  done_text
        Pterm0

; -----------------------------------------------------------------------------
; Control-rate spike
; -----------------------------------------------------------------------------

; Arm the profiler with a marker naming the run and the block length, then
; hand the DSP the run's payload - static constants, block length and count,
; one control record per block - and print the checksum it replies with once
; the blocks are rendered. tools/control_rate.py generated the payloads and
; checks the DSP's buffer against the oracle's held render.
; out: d0.l = 0 on success
run_control:
        move.l  profile_cfg,d0
        lsl.l   #4,d0
        or.l    control_ncode,d0
        or.l    #MT32_CONTROL_MARKER,d0
        bsr     dsp_exchange
        cmp.l   #MT32_REPLY_HELLO,d0
        bne.s   run_control_failed
        move.l  profile_cfg,d0
        mulu.w  #LA32_CONTROL_LENGTHS,d0
        add.l   control_ncode,d0
        lsl.l   #3,d0                   ; eight bytes per table entry
        lea     ctrl_payload_table,a0
        movea.l (a0,d0.l),a3
        move.l  4(a0,d0.l),d3
        move.l  #MT32_CMD_CONTROL_RUN,d0
        bsr     dsp_send_block
        cmp.l   #MT32_REPLY_BLOCK_READY,d0
        beq.s   run_control_failed      ; the DSP never took the payload
        lea     txt_control_checksum,a0
        bsr     report_value
        moveq   #0,d0
        rts
run_control_failed:
        moveq   #-1,d0
        rts

; -----------------------------------------------------------------------------
; LA32 profile spike
; -----------------------------------------------------------------------------

; Arm the Hatari cycle profiler with a PING whose payload names the
; configuration, then have the DSP render that configuration and print the
; checksum it folded from its output buffer. tools/la32_partial.py checks
; the buffer itself against the Munt oracle from the emulator's memory dump.
; out: d0.l = 0 on success
run_profile:
        move.l  #MT32_PROFILE_MARKER,d0
        or.l    profile_cfg,d0
        bsr     dsp_exchange
        cmp.l   #MT32_REPLY_HELLO,d0
        bne.s   run_profile_failed
        move.l  #MT32_CMD_PROFILE_PARTIAL,d0
        or.l    profile_cfg,d0
        bsr     dsp_exchange
        lea     txt_profile_checksum,a0
        bsr     report_value
        moveq   #0,d0
        rts
run_profile_failed:
        moveq   #-1,d0
        rts

; -----------------------------------------------------------------------------
; 68030 PCM partial spike
; -----------------------------------------------------------------------------

; Render the selected run twice: once for the oracle comparison, into the
; buffer the file carries, and then period after period between the two
; marker PINGs that bracket the Hatari CPU profiler, with the 200 Hz system
; tick counted around the timed render so the same program measures itself
; on hardware. tools/pcm_partial.py reads the file and the profile.
; out: d0.l = 0 on success
run_pcm:
        bsr     pcm_prepare
        move.l  profile_cfg,d0
        mulu.w  #PCM_CFG_BYTES,d0
        lea     pcm_cfg_image,a0
        adda.l  d0,a0
        move.l  a0,pcm_run_config

        clr.l   pcm_position
        clr.l   pcm_ended
        lea     pcm_output,a1
        move.l  #PCM_PROFILE_FRAMES,d0
        bsr     pcm_render

        move.l  #MT32_PCM_MARKER_BEGIN,d0
        or.l    profile_cfg,d0
        bsr     dsp_exchange
        cmp.l   #MT32_REPLY_HELLO,d0
        bne     run_pcm_failed
        Supexec read_hz200
        move.l  d0,d7
        move.w  #PCM_TIMING_PERIODS-1,d6
run_pcm_timing:
        ; Every timed period starts the wave over, so a one-shot wave is
        ; rendered rather than silenced, and a looped one is unaffected.
        clr.l   pcm_position
        clr.l   pcm_ended
        movea.l pcm_run_config,a0
        lea     pcm_scratch,a1
        move.l  #MT32_PERIOD_FRAMES,d0
        bsr     pcm_render
        dbra    d6,run_pcm_timing
        Supexec read_hz200
        sub.l   d7,d0
        move.l  d0,pcm_output_header+12
        move.l  #MT32_PCM_MARKER_END,d0
        or.l    profile_cfg,d0
        bsr     dsp_exchange
        cmp.l   #MT32_REPLY_HELLO,d0
        bne     run_pcm_failed

        move.l  #'PCM1',pcm_output_header
        move.l  #PCM_PROFILE_FRAMES,pcm_output_header+4
        move.l  #PCM_TIMING_PERIODS,pcm_output_header+8
        move.l  profile_cfg,pcm_output_header+16
        Fcreate pcm_output_name,#0
        tst.l   d0
        bmi.s   run_pcm_failed
        move.w  d0,d7
        Fwrite  d7,#PCM_OUTPUT_BYTES,pcm_output_header
        move.l  d0,d6
        Fclose  d7
        cmpi.l  #PCM_OUTPUT_BYTES,d6
        bne.s   run_pcm_failed
        move.l  pcm_output_header+12,d0
        lea     txt_pcm_ticks,a0
        bsr     report_value
        moveq   #0,d0
        rts
run_pcm_failed:
        moveq   #-1,d0
        rts

; The TOS 200 Hz tick, supervisor only; run through Supexec.
read_hz200:
        move.l  $4ba.w,d0
        rts

; Hatari's autostart cannot pass a command tail, so a PROFILE.CFG beside the
; program selects a spike the way F030MXDRV's AUTOPLAY.INF selects a song:
; one digit for the DSP runs, P and two digits for the 68030 PCM runs, C
; and two digits - run and block-length code - for the control-rate runs.
; Absent, unreadable or out of range means the self-test.
; out: d0.l = MODE_PROFILE, MODE_PCM or MODE_CONTROL with profile_cfg set,
;      or MODE_SELFTEST
read_profile_cfg:
        Fopen   profile_cfg_name,#0
        tst.l   d0
        bmi     read_profile_cfg_none
        move.w  d0,d7                   ; handle; GEMDOS preserves d3-d7
        Fread   d7,#4,profile_cfg_bytes
        move.l  d0,d6
        Fclose  d7
        tst.l   d6
        ble     read_profile_cfg_none
        moveq   #0,d0
        move.b  profile_cfg_bytes,d0
        andi.b  #$df,d0
        cmpi.b  #'P',d0
        beq.s   read_profile_cfg_pcm
        cmpi.b  #'C',d0
        beq.s   read_profile_cfg_control
        bra     read_profile_cfg_dsp
read_profile_cfg_pcm:
        cmpi.l  #3,d6
        bne     read_profile_cfg_none
        moveq   #0,d0
        move.b  profile_cfg_bytes+1,d0
        subi.b  #'0',d0
        cmpi.b  #9,d0
        bhi     read_profile_cfg_none
        mulu.w  #10,d0
        moveq   #0,d1
        move.b  profile_cfg_bytes+2,d1
        subi.b  #'0',d1
        cmpi.b  #9,d1
        bhi     read_profile_cfg_none
        add.l   d1,d0
        cmpi.l  #PCM_PROFILE_CONFIGS-1,d0
        bhi     read_profile_cfg_none
        move.l  d0,profile_cfg
        moveq   #MODE_PCM,d0
        rts
read_profile_cfg_control:
        cmpi.l  #4,d6
        bne     read_profile_cfg_none
        moveq   #0,d0
        move.b  profile_cfg_bytes+3,d0
        subi.b  #'0',d0
        cmpi.b  #LA32_CONTROL_LENGTHS-1,d0
        bhi     read_profile_cfg_none
        move.l  d0,control_ncode
        moveq   #0,d0
        move.b  profile_cfg_bytes+1,d0
        subi.b  #'0',d0
        cmpi.b  #9,d0
        bhi     read_profile_cfg_none
        mulu.w  #10,d0
        moveq   #0,d1
        move.b  profile_cfg_bytes+2,d1
        subi.b  #'0',d1
        cmpi.b  #9,d1
        bhi     read_profile_cfg_none
        add.l   d1,d0
        cmpi.l  #LA32_CONTROL_CONFIGS-1,d0
        bhi     read_profile_cfg_none
        move.l  d0,profile_cfg
        moveq   #MODE_CONTROL,d0
        rts
read_profile_cfg_dsp:
        moveq   #0,d0
        move.b  profile_cfg_bytes,d0
        subi.b  #'0',d0
        cmpi.b  #LA32_PROFILE_CONFIGS-1,d0
        bhi     read_profile_cfg_none
        move.l  d0,profile_cfg
        moveq   #MODE_PROFILE,d0
        rts
read_profile_cfg_none:
        moveq   #MODE_SELFTEST,d0
        rts

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
        bra.s   fail_exit
profile_failed:
        Cconws  profile_error_text
        bra.s   fail_exit
pcm_failed:
        Cconws  pcm_error_text
        bra.s   fail_exit
control_failed:
        Cconws  control_error_text
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
txt_profile_checksum:
        dc.b    'partial checksum   ',0
txt_pcm_ticks:
        dc.b    'pcm 200 Hz ticks   ',0
txt_control_checksum:
        dc.b    'control checksum   ',0
profile_cfg_name:
        dc.b    'PROFILE.CFG',0
pcm_output_name:
        dc.b    'PCMOUT.BIN',0
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
profile_error_text:
        dc.b    'LA32 profile spike failed',13,10,0
pcm_error_text:
        dc.b    'PCM partial spike failed',13,10,0
control_error_text:
        dc.b    'control-rate spike failed',13,10,0
        even

; The control-run payloads: static constants and per-block records for
; every run and block length, generated by tools/control_rate.py.
        include "ctrltabs.i"

; The generated DSP image closes the data section, as in F030MXDRV. A TOS
; executable starts at the first byte of its text segment, so the image must
; never precede start: - included at the top of this file it assembled into
; text ahead of the entry point and TOS executed DSP words as 68030 code.
        include "dsp_stage2_image.i"
        include "dsp_reverb_image.i"

        bss

mt32_basepage:
        ds.l    1
run_mode:
        ds.l    1
dsp_stage2_reply:
        ds.l    1
host_phase:
        ds.l    1
profile_cfg:
        ds.l    1
dsp_image_ptr:
        ds.l    1
dsp_image_words:
        ds.l    1
pcm_run_config:
        ds.l    1
control_ncode:
        ds.l    1
profile_cfg_bytes:
        ds.b    4
        even
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
