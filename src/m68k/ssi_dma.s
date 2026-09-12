; Standalone transport probe. Runs only from make profile-ssi-dma.
; Constant input is intentional: this measures transport overhead, not PCM
; generation, live buffering, MIDI, or the complete synthesis deadline.
        include "xbios.i"
        include "dmacfg.i"
        text
start:
        Locksnd
        cmpi.l  #1,d0
        bne     failed
        Buffoper #0
        Sndstatus #1
        Setmode #1
        Settracks #DMA_CHANNELS/2-1,#0
        Setmontracks #0
        Dsptristate #1,#1
        Devconnect #0,#2,#0,#2,#1      ; DMA playback -> DSP RX, 32.78 kHz
        Devconnect #1,#8,#0,#2,#1      ; DSP TX -> DAC at the same clock
        Setbuffer #0,#dma_input,#dma_input_end
        Dsp_ExecBoot dma_boot,#DMA_BOOT_WORDS,#3
        Dsp_BlkUnpacked command,#1,reply,#1
        cmpi.l  #$4d5401,reply
        bne.s   cleanup_failed
        Buffoper #3                   ; repeat the one-period pattern
        move.w  #79,d7
wait:
        Vsync                         ; leave CPU available while DMA runs
        dbra    d7,wait
        Dsp_BlkUnpacked command,#1,reply,#1
        cmpi.l  #$4d5401,reply
        bne.s   cleanup_failed
        bsr.s   cleanup
        Pterm0
cleanup_failed:
        bsr.s   cleanup
failed:
        move.w  #1,-(sp)
        move.w  #$4c,-(sp)
        trap    #1
cleanup:
        Buffoper #0
        Dsptristate #0,#0
        Devconnect #0,#0,#0,#2,#1
        Devconnect #1,#0,#0,#2,#1
        Settracks #0,#0
        Unlocksnd
        rts
        data
command: dc.l $010000
reply:  dc.l 0
        include "dmaimage.i"
        include "dmainput.i"
        end
