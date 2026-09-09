; F030MT32 DSP reverb profile image
;
; The same kernel source as la32.asm, assembled with LA32_REVERB_IMAGE
; defined: the transport is unchanged, the LA32 partial loops and their
; tables are replaced by the Boss reverb loop, its delay lines and the input
; frames the loop processes in place. The 68030 boots this image instead of
; the partial one for the reverb runs of MT32_CMD_PROFILE_PARTIAL; see
; docs/la32-budget.md.

LA32_REVERB_IMAGE equ   1

        include 'LA32.ASM'
