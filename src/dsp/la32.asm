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

        include 'ioequ.inc'
        include 'protocol.inc'

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
; State in the short-addressable internal X page
; -----------------------------------------------------------------------------

        org     x:$0

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

; The 256-entry test-tone table lives in internal Y so the generator never
; touches external memory. Initialized data cannot be shipped in Y: the
; stage-two loader carries P sections only, so the table is assembled into P
; and copied here at boot (see tone_table_install).
        org     y:$0
tone_sine:
        ds      TONE_TABLE_WORDS

; Two interleaved stereo periods in external X. Both bases are 1024-word
; aligned because the SSI output pointer runs modulo MT32_PERIOD_MODULO, and
; ds keeps them out of the loader image. External X decodes at phys+$4000 on
; the Falcon, clear of the P/Y alias in the lower 16K.
        org     x:$1000
ssi_buffer_a:
        ds      MT32_PERIOD_WORDS

        org     x:$1400
ssi_buffer_b:
        ds      MT32_PERIOD_WORDS

; -----------------------------------------------------------------------------
; Kernel
; -----------------------------------------------------------------------------

        org     p:$80

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

        jsr     tone_table_install
        jsr     mt32_reset

; Idle command loop. Everything that needs the codec running is dispatched
; from one of the two audio loops below instead.
command_loop:
        jclr    #0,x:m_hsr,*            ; wait for host receive data full
        movep   x:m_hrx,x1
        move    x1,x:last_command

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
        move    x:last_command,a
        move    #>$00ffff,y0
        and     y0,a1
        move    a1,x:tone_step
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

command_query_time:
        move    x:ssi_frame_count,a
        jsr     send_reply
        jmp     command_loop

command_query_periods:
        move    x:ssi_period_count,a
        jsr     send_reply
        jmp     command_loop

; -----------------------------------------------------------------------------
; Source 1: DSP-generated tone
; -----------------------------------------------------------------------------

; Prove the codec path with no host data dependency at all: crossbar clock,
; SSI framing, DAC routing and the period handoff are all exercised, and a
; frozen or absent SSI clock shows up as silence with a stalled frame count
; rather than as a plausible-sounding wrong result.
command_start_tone:
        move    #>1,a
        move    a1,x:source_mode
        jsr     ssi_configure
        move    x:ssi_active_base,r0
        jsr     render_tone_period
        jsr     ssi_begin

tone_loop:
        move    x:ssi_refill_base,r0
        jsr     render_tone_period
tone_wait:
        move    x:ssi_active_base,x0
        move    r6,a
        cmp     x0,a
        jeq     tone_handoff
        jclr    #0,x:m_hsr,tone_wait
        movep   x:m_hrx,x1
        move    x1,x:last_command
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
        move    x:ssi_frame_count,a
        jsr     send_reply
        jmp     tone_wait

tone_query_periods:
        move    x:ssi_period_count,a
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
        move    a1,x:source_mode
        jsr     ssi_configure
        move    x:ssi_active_base,r0
        jsr     receive_period
        jsr     ssi_begin

; While buffered audio is active, accept refills, queries, and stop.
stream_loop:
        jclr    #0,x:m_hsr,stream_loop
        movep   x:m_hrx,x1
        move    x1,x:last_command
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
        move    x:ssi_frame_count,a
        jsr     send_reply
        jmp     stream_loop

stream_query_periods:
        move    x:ssi_period_count,a
        jsr     send_reply
        jmp     stream_loop

; Take one host period into the buffer the SSI is not playing, acknowledge it
; as soon as it is private DSP memory so the 68030 can start preparing the
; next one, then switch at the next complete stereo boundary. A late host
; leaves the current period untouched and audible: it repeats whole rather
; than tearing.
command_refill_stream:
        move    x:ssi_refill_base,r0
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
        move    a1,x:ssi_frame_count
        move    a1,x:ssi_period_count
        move    #>ssi_buffer_a,a
        move    a1,x:ssi_active_base
        move    #>ssi_buffer_b,a
        move    a1,x:ssi_refill_base
        rts

; Prime the transmitter from the active buffer and enable the network transmit
; interrupt. The modulo pointer then repeats that period until a handoff, so a
; renderer that misses its deadline costs a repeat and never a discontinuity.
ssi_begin:
        move    x:ssi_active_base,r6
        move    #>MT32_PERIOD_MODULO,m6
        nop
        move    x:(r6)+,a
        movep   a1,x:m_tx
        move    #>MT32_PERIOD_FRAMES,a
        move    a1,x:ssi_frame_count
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        movep   #$5a00,x:m_crb          ; network TX + SSI transmit interrupt
        rts

; Spin until the output pointer wraps back to the active buffer base. r6
; equals that base for one whole word period (about 30 us), which this loop
; samples every few instruction cycles.
ssi_wait_boundary:
        move    x:ssi_active_base,x0
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
        move    x:ssi_active_base,a
        move    x:ssi_refill_base,b
        move    b1,x:ssi_active_base
        move    a1,x:ssi_refill_base
        move    b1,r6
        move    x:ssi_frame_count,a
        move    #>MT32_PERIOD_FRAMES,x0
        add     x0,a
        move    a1,x:ssi_frame_count
        move    x:(r6)+,a
        movep   a1,x:m_tx
        movep   #$5a00,x:m_crb
        move    x:ssi_period_count,a
        move    #>1,x0
        add     x0,a
        move    a1,x:ssi_period_count
        rts

command_stop_audio:
        movep   #0,x:m_crb
        move    #>-1,m6
        clr     a
        movep   a1,x:m_tx
        move    a1,x:source_mode
        move    #>MT32_REPLY_OK,a
        jsr     send_reply
        jmp     command_loop

; SSI transmit-underrun recovery. Reading SSISR followed by writing TX clears
; TUE; this long exception path is not part of normal buffered playback, and
; the retained status word says whether it was ever taken.
ssi_tx_exception:
        movep   x:m_sr,x:ssi_status_snapshot
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
        move    a1,x:ssi_frame_count
        move    a1,x:ssi_period_count
        move    a1,x:ssi_status_snapshot
        move    a1,x:tone_phase
        move    a1,x:source_mode
        move    #>MT32_TONE_A440_STEP,a
        move    a1,x:tone_step
        move    #>ssi_buffer_a,a
        move    a1,x:ssi_active_base
        move    #>ssi_buffer_b,a
        move    a1,x:ssi_refill_base
        rts

tone_table_install:
        move    #tone_table_image,r1
        move    #tone_sine,r4
        do      #TONE_TABLE_WORDS,tone_table_install_done
        move    p:(r1)+,a
        move    a1,y:(r4)+
tone_table_install_done:
        rts

; Fill one whole period with a centred mono sine. The table words are already
; positioned for the 16-bit SSI word length, so the inner loop is one table
; read and two stores.
; in:  r0 = destination base
; out: r0 = one past the period
render_tone_period:
        move    #tone_sine,r1
        move    #>$00ffff,y1
        move    x:tone_phase,a
        move    x:tone_step,x0
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
        move    a1,x:tone_phase
        rts

; The generated table is P-memory data, not code: the stage-two loader carries
; P sections only, and generate_dsp_stage2.py fails the build if the kernel
; above ever grows into this address.
        org     p:$400
        include 'tonetabs.inc'          ; DOS assembler requires an 8.3 name

        end
