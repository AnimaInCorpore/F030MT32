        include "xbios.i"
        include "protocol.i"

        global  run_file

FILE_CACHE_BYTES equ 16384

        text

; Play MT32.PCM produced by MT32REND. Header: "F32P", codec numerator,
; denominator, frame count (all big-endian u32), then big-endian stereo s16.
; Disk I/O runs in user mode. Only the existing paced DSP transfer is super.
; out: d0 = 0 on complete playback/key cancel, -1 on file/protocol failure.
run_file:
        clr.b   file_started
        clr.l   file_cached
        move.l  #-1,file_handle
        Fopen   file_name,#0
        tst.l   d0
        bmi     file_failed
        move.l  d0,file_handle
        Fread   file_handle+2,#16,file_header
        cmpi.l  #16,d0
        bne     file_failed
        cmpi.l  #$46333250,file_header
        bne     file_failed
        cmpi.l  #25175000,file_header+4
        bne     file_failed
        cmpi.l  #768,file_header+8
        bne     file_failed
        move.l  file_header+12,d6
        beq     file_failed
        cmpi.l  #$1ffffffb,d6           ; size calculation stays signed 32-bit
        bhi     file_failed
        lsl.l   #2,d6
        move.l  d6,file_remaining
        addi.l  #16,d6
        Fseek   #0,file_handle+2,#2
        cmp.l   d6,d0
        bne     file_failed
        Fseek   #16,file_handle+2,#0
        cmpi.l  #16,d0
        bne     file_failed
        Cconws  file_playing
file_next:
        bsr     file_fill_period
        tst.l   d0
        bne     file_failed
        move.l  #MT32_CMD_REFILL_STREAM,d0
        tst.b   file_started
        bne.s   file_send
        move.l  #MT32_CMD_START_STREAM,d0
file_send:
        lea     file_period,a3
        move.l  #MT32_PERIOD_WORDS,d3
        bsr     dsp_send_block
        cmpi.l  #MT32_REPLY_OK,d0
        bne     file_failed
        move.b  #1,file_started
        Cconis
        tst.w   d0
        bne.s   file_cancel
        move.l  file_remaining,d0
        or.l    file_cached,d0
        bne.s   file_next

        ; A refill ACK means the final period has just STARTED. Swap a zero
        ; period in after it so the last 512 frames reach the codec in full.
        bsr     file_fill_period
        lea     file_period,a3
        move.l  #MT32_PERIOD_WORDS,d3
        move.l  #MT32_CMD_REFILL_STREAM,d0
        bsr     dsp_send_block
        cmpi.l  #MT32_REPLY_OK,d0
        bne.s   file_failed
        bra.s   file_success
file_cancel:
        Cconin
file_success:
        moveq   #0,d7
        bra.s   file_close
file_failed:
        moveq   #-1,d7
file_close:
        tst.b   file_started
        beq.s   file_close_handle
        move.l  #MT32_CMD_STOP_AUDIO,d0
        bsr     dsp_exchange
        cmpi.l  #MT32_REPLY_OK,d0
        beq.s   file_close_handle
        moveq   #-1,d7
file_close_handle:
        tst.l   file_handle
        bmi.s   file_return
        Fclose  file_handle+2
file_return:
        move.l  d7,d0
        rts

; Cache several periods per disk read; pad only the final partial period.
file_fill_period:
        lea     file_period,a0
        move.w  #MT32_PERIOD_WORDS-1,d0
file_clear:
        clr.l   (a0)+
        dbra    d0,file_clear
        tst.l   file_cached
        bne.s   file_convert
        move.l  file_remaining,d6
        beq.s   file_fill_ok
        cmpi.l  #FILE_CACHE_BYTES,d6
        bls.s   file_read
        move.l  #FILE_CACHE_BYTES,d6
file_read:
        Fread   file_handle+2,d6,file_cache
        cmp.l   d6,d0
        bne.s   file_fill_error
        sub.l   d6,file_remaining
        move.l  d6,file_cached
        lea     file_cache,a0
        move.l  a0,file_cache_ptr
file_convert:
        move.l  file_cached,d6
        cmpi.l  #MT32_PERIOD_FRAMES*4,d6
        bls.s   file_convert_size
        move.l  #MT32_PERIOD_FRAMES*4,d6
file_convert_size:
        sub.l   d6,file_cached
        lsr.l   #1,d6                  ; 16-bit sample words, always stereo pairs
        subq.w  #1,d6
        movea.l file_cache_ptr,a0
        lea     file_period,a1
file_convert_word:
        moveq   #0,d0
        move.w  (a0)+,d0
        lsl.l   #8,d0                  ; left-justify in a padded 24-bit DSP word
        move.l  d0,(a1)+
        dbra    d6,file_convert_word
        move.l  a0,file_cache_ptr
file_fill_ok:
        moveq   #0,d0
        rts
file_fill_error:
        moveq   #-1,d0
        rts

        data
file_name:      dc.b 'MT32.PCM',0
file_playing:   dc.b 'Playing MT32.PCM - press a key to stop',13,10,0
        even
        bss
file_handle:    ds.l 1
file_remaining: ds.l 1
file_cached:    ds.l 1
file_cache_ptr: ds.l 1
file_header:    ds.l 4
file_started:   ds.w 1
file_cache:     ds.b FILE_CACHE_BYTES
file_period:    ds.l MT32_PERIOD_WORDS
        end
