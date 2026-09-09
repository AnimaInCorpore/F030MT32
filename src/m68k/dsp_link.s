        include "xbios.i"
        include "verbose.i"
        include "protocol.i"

        global  dsp_exchange
        global  dsp_blast_paced
        global  dsp_send_block

; Falcon DSP host interface. ISR bit 0 = RXDF, bit 1 = TXDE; the 24-bit data
; word lives in three byte registers, and the low byte carries the transfer
; strobe in both directions.
DSP_HOST_ISR equ $ffffa202
DSP_HOST_DATA equ $ffffa204

        text

; Exchange one packed 24-bit protocol word with the DSP.
; in:  d0.l = command (low 24 bits)
; out: d0.l = reply   (low 24 bits)
dsp_exchange:
        movem.l d1-d7/a0-a6,-(sp)
        move.l  d0,dsp_tx_word
        clr.l   dsp_rx_word
        Dsp_BlkUnpacked dsp_tx_word,#1,dsp_rx_word,#1
        move.l  dsp_rx_word,d0
        movem.l (sp)+,d1-d7/a0-a6
        rts

; Send a payload with every word paced on TXDE, then collect the single reply
; word. TOS's Dsp_BlkUnpacked polls TXDE only for its first word and blasts
; the rest blind, which outruns a receive loop in external DSP P RAM and drops
; words on real TOS 4.02 hardware. Pacing each word costs well under a
; millisecond per 1024-word period against the 15.62 ms period. The host port
; is supervisor-only, so the two halves run under Supexec - two XBIOS traps
; per block instead of one per word - split so the verbose marker between
; payload and reply keeps separating "stopped consuming mid-block" from "took
; the block and never replied".
; in:  a3 = payload (zero-padded 24-bit words in 32-bit slots)
;      d3.l = word count
; out: d0.l = reply
dsp_blast_paced:
        move.l  a3,dsp_blast_ptr
        move.l  d3,dsp_blast_count
        Supexec dsp_blast_send_super
        VB      vb_txt_payloadsent
        Supexec dsp_blast_recv_super
        move.l  dsp_blast_reply,d0
        rts

dsp_blast_send_super:
        movem.l d3/a3,-(sp)
        ; An interrupt inside this short critical stream would otherwise leave
        ; the DSP parked at HRDF long enough to turn one late period into a
        ; repeated one. Preserve the caller's mask and defer; nothing is lost.
        move.w  sr,-(sp)
        ori.w   #$0700,sr
        move.l  dsp_blast_ptr,a3
        move.l  dsp_blast_count,d3
dsp_blast_send_word:
        btst    #1,DSP_HOST_ISR
        beq.s   dsp_blast_send_word
        ; Each payload slot is already a zero-padded 24-bit word. A long write
        ; covers TX0:TXH:TXM:TXL and the low-byte access still strobes the
        ; transfer, but the 68030 pays for one host-port transaction instead
        ; of three separately wait-stated byte writes.
        move.l  (a3)+,DSP_HOST_DATA
        subq.l  #1,d3
        bne.s   dsp_blast_send_word
        move.w  (sp)+,sr
        movem.l (sp)+,d3/a3
        rts

; The low data byte must be read last: reading it clears RXDF.
dsp_blast_recv_super:
        btst    #0,DSP_HOST_ISR
        beq.s   dsp_blast_recv_super
        moveq   #0,d0
        move.b  DSP_HOST_DATA+1,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+2,d0
        lsl.l   #8,d0
        move.b  DSP_HOST_DATA+3,d0
        move.l  d0,dsp_blast_reply
        rts

; Announce a block command, wait for the DSP's parked-receiver token, release
; the payload, and return the acknowledgement. A wrong token is returned
; unchanged so the caller's OK check fails instead of the payload being sent
; into a DSP that is not listening.
; in:  d0.l = command, a3 = payload base, d3.l = payload word count
; out: d0.l = final reply, or the offending token
dsp_send_block:
        bsr     dsp_exchange
        VBH
        cmp.l   #MT32_REPLY_BLOCK_READY,d0
        bne.s   dsp_send_block_done
        VBV     vb_txt_blockwords,d3
        bsr     dsp_blast_paced
dsp_send_block_done:
        rts

        ifd     VERBOSE_BOOT
        data
vb_txt_blockwords:  dc.b 'block words      ',0
vb_txt_payloadsent: dc.b 'payload sent, awaiting reply',13,10,0
        even
        endc

        bss

dsp_tx_word:
        ds.l    1
dsp_rx_word:
        ds.l    1
dsp_blast_ptr:
        ds.l    1
dsp_blast_count:
        ds.l    1
dsp_blast_reply:
        ds.l    1

        end
