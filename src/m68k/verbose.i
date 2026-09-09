; Optional boot/init tracing for real-hardware bring-up.
;
; Assemble with -DVERBOSE_BOOT to compile the markers in; without it every
; VB/VBH expands to nothing, so the normal f030mt32.tos and tonetest.tos
; builds are unaffected. Requires xbios.i (for Cconws) to be included first.
;
; Every blocking XBIOS/DSP step prints its label BEFORE the call and its
; result AFTER, so a hang leaves the label on screen with no result behind
; it: the last complete line is the last step that finished, and the
; dangling label names the call that never returned.

        macro   VB
        ifd     VERBOSE_BOOT
        movem.l d0-d2/a0-a2,-(sp)
        Cconws  \1
        movem.l (sp)+,d0-d2/a0-a2
        endc
        endm

; Print d0.l as eight hex digits followed by CRLF, preserving every register.
        macro   VBH
        ifd     VERBOSE_BOOT
        bsr     vb_hex
        endc
        endm

; Print a NUL-terminated string whose address is in a0, then CRLF.
        macro   VBS
        ifd     VERBOSE_BOOT
        bsr     vb_string
        endc
        endm

; Label plus a value that only the trace cares about: \1 = label string,
; \2 = longword source. The fetch lives inside the guard, so nothing of this
; reaches the shipping build.
        macro   VBV
        ifd     VERBOSE_BOOT
        movem.l d0-d2/a0-a2,-(sp)
        Cconws  \1
        movem.l (sp)+,d0-d2/a0-a2
        move.l  \2,d0
        bsr     vb_hex
        endc
        endm

; Label plus a NUL-terminated string at address \2, both trace-only.
        macro   VBN
        ifd     VERBOSE_BOOT
        movem.l d0-d2/a0-a2,-(sp)
        Cconws  \1
        movem.l (sp)+,d0-d2/a0-a2
        lea     \2,a0
        bsr     vb_string
        endc
        endm
