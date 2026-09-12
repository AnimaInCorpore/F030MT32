; Standalone DMA -> SSI receive feasibility probe, not the live renderer.
; The host supplies a repeating, slot-distinct 16-bit pattern. Capture one
; period while transmitting silence to the DAC at the same clock and track
; count. All interrupt handlers preserve the foreground ALU state.
        include 'ioequ.inc'
        include 'dmacfg.inc'
        org     p:$0
        jmp     start
        org     p:$0c
ssi_rx:
        movep   x:m_rx,x:(r0)+
        lua     (r1)+,r1
        org     p:$0e
        jsr     rx_error
        org     p:$10
ssi_tx:
        movep   x:(r6)+,x:m_tx
        lua     (r7)+,r7
        org     p:$12
        jsr     tx_error
        org     p:$40
start:
        movep   #1,x:m_pbc
        movep   #$1f8,x:m_pcc
        movep   #0,x:m_bcr
        movep   #$3000,x:m_ipr
        movep   #0,x:m_crb
        movep   #($4000+(DMA_CHANNELS-1)*$100),x:m_cra
        move    #>$1000,r0
        move    #>DMA_WORDS-1,m0
        move    #>0,r1
        move    #>-1,m1
        move    #>0,r3                  ; receive exceptions
        move    #>-1,m3
        move    #>0,r4                  ; transmit exceptions
        move    #>-1,m4
        move    #>$20,r6
        move    #>DMA_CHANNELS-1,m6
        move    #>0,r7
        move    #>-1,m7
        clr     a
        do      #DMA_CHANNELS,clear_done
        move    a1,x:(r6)+
clear_done:
        nop
        movep   a1,x:m_tx              ; prime transmitter before enabling
        andi    #$fc,mr
        jclr    #0,x:m_hsr,*
        movep   x:m_hrx,a              ; host arms after configuring the matrix
        movep   #$f800,x:m_crb         ; async RX/TX, network mode, both IRQs
        move    #>$4d5401,a
        jclr    #1,x:m_hsr,*
        movep   a1,x:m_htx
capture_begin:
        jclr    #0,x:m_hsr,*            ; all input arrives by DMA/SSI, not this port
        movep   x:m_hrx,a
        movep   #0,x:m_crb
        move    r1,y:$0
        move    r7,y:$1
        move    r3,y:$2
        move    r4,y:$3
        move    r0,y:$4
        movep   x:m_sr,y:$5
capture_done:
        move    #>$4d5401,a
        jclr    #1,x:m_hsr,*
        movep   a1,x:m_htx
halt:
        jmp     halt
rx_error:
        movep   x:m_sr,y:$6
        movep   x:m_rx,x:(r0)+
        lua     (r1)+,r1
        lua     (r3)+,r3
        rti
rx_error_done:
        nop
tx_error:
        movep   x:m_sr,y:$7
        movep   x:(r6)+,x:m_tx
        lua     (r7)+,r7
        lua     (r4)+,r4
        rti
tx_error_done:
        nop
        end
