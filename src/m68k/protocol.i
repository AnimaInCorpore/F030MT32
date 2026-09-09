; Host/DSP protocol. Keep in sync with src/dsp/protocol.inc.
;
; Every transport unit is one 24-bit DSP/host word whose upper byte is an
; opcode, exactly as in F030MXDRV. Version 1 is the scaffold surface: boot
; handshake, codec transport, and the two bring-up sources. No LA32 synthesis
; opcode is allocated yet - see docs/architecture.md.

MT32_PROTOCOL_VERSION equ   1

MT32_CMD_PING       equ     $010000 ; -> hello token
MT32_CMD_RESET      equ     $020000 ; clear transport state, stay in the loop
MT32_CMD_SET_TONE   equ     $030000 ; low 16 bits = test-tone phase step
MT32_CMD_START_TONE equ     $040000 ; DSP-generated tone, no host data path
MT32_CMD_START_STREAM equ   $050000 ; host-fed stereo periods
MT32_CMD_REFILL_STREAM equ  $060000 ; one more host-fed period
MT32_CMD_STOP_AUDIO equ     $070000 ; halt SSI, return to the command loop
MT32_CMD_QUERY_TIME equ     $080000 ; -> codec frames emitted, modulo 2^24
MT32_CMD_QUERY_PERIODS equ  $090000 ; -> completed period handoffs

; One transport period. 512 stereo frames at the 32,779.947916 Hz codec rate
; is 15.62 ms, the same cadence F030MXDRV's production path was calibrated
; against; the interleaved buffer is therefore 1024 words and must sit on a
; 1024-word boundary for the SSI modulo pointer.
MT32_PERIOD_FRAMES  equ     512
MT32_PERIOD_WORDS   equ     1024
MT32_PERIOD_MODULO  equ     1023

; Native LA32 time against the Falcon codec. 32,000 : 25,175,000/768 reduces
; to exactly 24576:25175, so one codec frame advances native time by
; 24576/25175 samples with no long-term drift. The production renderer is
; planned to run at codec rate with pitch scaled by this ratio and to use the
; DDA only for control timing; see docs/architecture.md.
MT32_NATIVE_NUMERATOR equ   24576
MT32_NATIVE_DENOMINATOR equ 25175

; Bring-up test tone. The DSP walks a 256-entry sine with a 16-bit phase
; accumulator, so the step for frequency f is round(65536 * f / 32779.947916).
; A440 rounds to 880, which sounds at 440.160 Hz. That 0.6-cent error is
; deliberate: an integer step keeps the table index exact forever, and the
; tone is a transport probe rather than a pitch reference.
TONE_TABLE_WORDS    equ     256
MT32_TONE_A440_STEP equ     880

MT32_REPLY_HELLO    equ     $4d5401 ; "MT", version 1
MT32_REPLY_BLOCK_READY equ  $524459 ; "RDY": parked receiver, send the block
MT32_REPLY_OK       equ     $000000
MT32_REPLY_ERROR    equ     $ffffff
