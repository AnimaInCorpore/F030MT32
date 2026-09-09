; F030MT32 DSP second-stage program loader
;
; Dsp_ExecBoot installs this image in the DSP56001's 512-word internal P RAM.
; The first-stage reset vector jumps into the program gap left after the vector
; table by the final LA32 program, so that program can replace P:$0000,
; P:$0010, and P:$0012 while the loader is still receiving its remaining
; P-memory sections.
;
; Unchanged from the F030MXDRV loader apart from the stream magic: XBIOS can
; boot at most 512 contiguous internal-P words, and the converted-LOD path has
; an 8 KiB ceiling that an LA32 kernel will not fit under.

        include 'ioequ.inc'

STAGE2_MAGIC    equ     $4d544c         ; "MTL"
STAGE2_REPLY_OK equ     $4c4f41         ; "LOA"
STAGE2_REPLY_ERROR equ  $ffffff

        org     p:$0000
        jmp     stage2_loader

; The final program reserves P:$0040-$007f for this transient loader. Keeping
; it above P:$003f also avoids every hardware interrupt-vector slot.
        org     p:$0040

stage2_loader:
        movep   #1,x:m_pbc              ; enable the Falcon host port

        jclr    #0,x:m_hsr,*            ; validate stream magic
        movep   x:m_hrx,a
        move    #>STAGE2_MAGIC,x0
        cmp     x0,a
        jne     stage2_error

        jclr    #0,x:m_hsr,*            ; number of P-memory sections
        movep   x:m_hrx,a
        tst     a
        jeq     stage2_error

        do      a1,stage2_sections_done
        jclr    #0,x:m_hsr,*            ; destination P address
        movep   x:m_hrx,x1
        move    x1,r0

        jclr    #0,x:m_hsr,*            ; non-zero section word count
        movep   x:m_hrx,a
        tst     a
        jeq     stage2_error

        do      a1,stage2_words_done
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a
        move    a1,p:(r0)+
stage2_words_done:
        nop                              ; distinct outer hardware-loop end
stage2_sections_done:

        move    #>STAGE2_REPLY_OK,a
        jclr    #1,x:m_hsr,*
        movep   a1,x:m_htx
        jmp     $0000                    ; enter the installed program

stage2_error:
        move    #>STAGE2_REPLY_ERROR,a
        jclr    #1,x:m_hsr,*
        movep   a1,x:m_htx
stage2_halt:
        jmp     stage2_halt

        end
