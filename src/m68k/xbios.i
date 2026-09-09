; Minimal GEMDOS/XBIOS bindings used by the Falcon host.

        macro   Cconin
        move.w  #1,-(sp)
        trap    #1
        addq.l  #2,sp
        endm

        macro   Cconis
        move.w  #11,-(sp)
        trap    #1
        addq.l  #2,sp
        endm

        macro   Cconws string
        pea     \1
        move.w  #9,-(sp)
        trap    #1
        addq.l  #6,sp
        endm

        macro   Fclose handle
        move.w  \1,-(sp)
        move.w  #62,-(sp)
        trap    #1
        addq.l  #4,sp
        endm

        macro   Fcreate filename,attributes
        move.w  \2,-(sp)
        pea     \1
        move.w  #60,-(sp)
        trap    #1
        addq.l  #8,sp
        endm

        macro   Fopen filename,mode
        move.w  \2,-(sp)
        pea     \1
        move.w  #61,-(sp)
        trap    #1
        addq.l  #8,sp
        endm

        macro   Fread handle,count,buffer
        pea     \3
        move.l  \2,-(sp)
        move.w  \1,-(sp)
        move.w  #63,-(sp)
        trap    #1
        lea     12(sp),sp
        endm

        macro   Fseek offset,handle,mode
        move.w  \3,-(sp)
        move.w  \2,-(sp)
        move.l  \1,-(sp)
        move.w  #66,-(sp)
        trap    #1
        lea     10(sp),sp
        endm

        macro   Fwrite handle,count,buffer
        pea     \3
        move.l  \2,-(sp)
        move.w  \1,-(sp)
        move.w  #64,-(sp)
        trap    #1
        lea     12(sp),sp
        endm

        macro   Pterm0
        clr.w   -(sp)
        trap    #1
        endm

        macro   Vsync
        move.w  #37,-(sp)
        trap    #14
        addq.l  #2,sp
        endm

        macro   Supexec routine
        pea     \1
        move.w  #38,-(sp)
        trap    #14
        addq.l  #6,sp
        endm

        macro   Locksnd
        move.w  #128,-(sp)
        trap    #14
        addq.l  #2,sp
        endm

        macro   Unlocksnd
        move.w  #129,-(sp)
        trap    #14
        addq.l  #2,sp
        endm

        macro   Soundcmd mode,data
        move.w  \2,-(sp)
        move.w  \1,-(sp)
        move.w  #130,-(sp)
        trap    #14
        addq.l  #6,sp
        endm

        macro   Setmode mode
        move.w  \1,-(sp)
        move.w  #132,-(sp)
        trap    #14
        addq.l  #4,sp
        endm

        macro   Settracks play,record
        move.w  \2,-(sp)
        move.w  \1,-(sp)
        move.w  #133,-(sp)
        trap    #14
        addq.l  #6,sp
        endm

; Select which pair out of the crossbar's eight 16-bit frame slots reaches the
; DAC. The value survives across programs, so a player that fills slots 0/1
; must pin it rather than inherit it.
        macro   Setmontracks track
        move.w  \1,-(sp)
        move.w  #134,-(sp)
        trap    #14
        addq.l  #4,sp
        endm

; reset=1 reinitializes the converters and clears the latched overflow bits;
; reset=0 returns the current status, whose bits 4 and 5 report left and right
; codec clipping.
        macro   Sndstatus reset
        move.w  \1,-(sp)
        move.w  #140,-(sp)
        trap    #14
        addq.l  #4,sp
        endm

        macro   Setbuffer region,begin,end
        move.l  \3,-(sp)
        move.l  \2,-(sp)
        move.w  \1,-(sp)
        move.w  #131,-(sp)
        trap    #14
        lea     12(sp),sp
        endm

        macro   Buffoper mode
        move.w  \1,-(sp)
        move.w  #136,-(sp)
        trap    #14
        addq.l  #4,sp
        endm

        macro   Dsptristate transmit,receive
        move.w  \2,-(sp)
        move.w  \1,-(sp)
        move.w  #137,-(sp)
        trap    #14
        addq.l  #6,sp
        endm


        macro   Devconnect source,destinations,clock,prescale,protocol
        move.w  \5,-(sp)
        move.w  \4,-(sp)
        move.w  \3,-(sp)
        move.w  \2,-(sp)
        move.w  \1,-(sp)
        move.w  #139,-(sp)
        trap    #14
        lea     12(sp),sp
        endm

        macro   Dsp_Unlock
        move.w  #105,-(sp)
        trap    #14
        addq.l  #2,sp
        endm

        macro   Dsp_Reserve xwords,ywords
        move.l  \2,-(sp)
        move.l  \1,-(sp)
        move.w  #107,-(sp)
        trap    #14
        lea     10(sp),sp
        endm

        macro   Dsp_LoadProgram filename,ability,buffer
        pea     \3
        move.w  \2,-(sp)
        pea     \1
        move.w  #108,-(sp)
        trap    #14
        lea     12(sp),sp
        endm

; Reset the DSP and install at most 512 packed 24-bit words in internal P RAM.
; Unlike Dsp_ExecProg, this deliberately hands all later memory placement to
; the embedded bootstrap.
        macro   Dsp_ExecBoot codeptr,codesize,ability
        move.w  \3,-(sp)
        move.l  \2,-(sp)
        pea     \1
        move.w  #110,-(sp)
        trap    #14
        lea     12(sp),sp
        endm

; Transfer 24-bit DSP words held in 32-bit 68030 slots. Dsp_BlkWords (XBIOS
; 123) is not suitable here: it expands 16-bit CPU words to DSP words.
        macro   Dsp_BlkUnpacked input,input_count,output,output_count
        move.l  \4,-(sp)
        pea     \3
        move.l  \2,-(sp)
        pea     \1
        move.w  #98,-(sp)
        trap    #14
        lea     18(sp),sp
        endm
