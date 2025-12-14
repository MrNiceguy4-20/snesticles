//
//  DMAController.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import Foundation

final class DMAController {
    unowned let bus: Bus
    
    struct Channel {
        // Registers
        var control: UInt8 = 0      // $43x0 (DMAPx)
        var destReg: UInt8 = 0      // $43x1 (BBADx)
        var srcAddr: UInt16 = 0     // $43x2/3 (A1Tx)
        var srcBank: UInt8 = 0      // $43x4 (A1Bx)
        var count: UInt16 = 0       // $43x5/6 (DASx)
        var indirectBank: UInt8 = 0 // $43x7 (DASBx)
        var hdmaAddr: UInt16 = 0    // $43x8/9 (A2Ax)
        var hdmaLine: UInt8 = 0     // $43xA (NTRLx)
        
        // Internal HDMA State
        var hdmaActive: Bool = false
        var hdmaDoTransfer: Bool = false
        var indirectAddr: UInt16 = 0
        var repeatMode: Bool = false
        var lineCounter: UInt8 = 0
    }
    
    var channels = [Channel](repeating: Channel(), count: 8)
    var hdmaEnabled: UInt8 = 0
    
    init(bus: Bus) {
        self.bus = bus
    }
    
    func reset() {
        channels = [Channel](repeating: Channel(), count: 8)
        hdmaEnabled = 0
    }
    
    // MARK: - Register I/O
    
    func read(_ addr: UInt16) -> UInt8 {
        let c = Int((addr >> 4) & 0x7)
        let reg = addr & 0xF
        
        switch reg {
        case 0x0: return channels[c].control
        case 0x1: return channels[c].destReg
        case 0x2: return UInt8(channels[c].srcAddr & 0xFF)
        case 0x3: return UInt8(channels[c].srcAddr >> 8)
        case 0x4: return channels[c].srcBank
        case 0x5: return UInt8(channels[c].count & 0xFF)
        case 0x6: return UInt8(channels[c].count >> 8)
        case 0x7: return channels[c].indirectBank
        case 0x8: return UInt8(channels[c].hdmaAddr & 0xFF)
        case 0x9: return UInt8(channels[c].hdmaAddr >> 8)
        case 0xA: return channels[c].hdmaLine
        default: return 0xFF
        }
    }
    
    func write(_ addr: UInt16, _ value: UInt8) {
        let c = Int((addr >> 4) & 0x7)
        let reg = addr & 0xF
        
        switch reg {
        case 0x0: channels[c].control = value
        case 0x1: channels[c].destReg = value
        case 0x2: channels[c].srcAddr = (channels[c].srcAddr & 0xFF00) | UInt16(value)
        case 0x3: channels[c].srcAddr = (channels[c].srcAddr & 0x00FF) | (UInt16(value) << 8)
        case 0x4: channels[c].srcBank = value
        case 0x5: channels[c].count = (channels[c].count & 0xFF00) | UInt16(value)
        case 0x6: channels[c].count = (channels[c].count & 0x00FF) | (UInt16(value) << 8)
        case 0x7: channels[c].indirectBank = value
        case 0x8: channels[c].hdmaAddr = (channels[c].hdmaAddr & 0xFF00) | UInt16(value)
        case 0x9: channels[c].hdmaAddr = (channels[c].hdmaAddr & 0x00FF) | (UInt16(value) << 8)
        case 0xA: channels[c].hdmaLine = value
        default: break
        }
    }
    
    // MARK: - General DMA (GDMA)
    
    func startGDMA(_ enableMask: UInt8) {
        for i in 0..<8 {
            if (enableMask & (1 << i)) != 0 {
                performGDMA(channel: i)
            }
        }
    }
    
    private func performGDMA(channel: Int) {
        var ch = channels[channel]
        
        let direction = (ch.control & 0x80) != 0 // 1=Device->Mem, 0=Mem->Device
        let increment = (ch.control & 0x10) != 0 // 1=Dec, 0=Inc
        let fixed = (ch.control & 0x08) != 0     // 1=Fixed, 0=Adjust
        let mode = ch.control & 0x07
        
        let bAddr = 0x2100 + UInt16(ch.destReg)
        var aAddr = (UInt32(ch.srcBank) << 16) | UInt32(ch.srcAddr)
        var count = Int(ch.count)
        if count == 0 { count = 0x10000 }
        
        // Transfer Loop
        while count > 0 {
            let pattern = getTransferPattern(mode)
            
            for offset in pattern {
                if count <= 0 { break }
                
                let bTarget = UInt32(bAddr) + UInt32(offset)
                
                if !direction {
                    // Memory -> PPU/APU
                    let val = bus.read(aAddr)
                    // FIXED: Removed 'data:' label
                    bus.write(bTarget, val)
                } else {
                    // PPU/APU -> Memory
                    let val = bus.read(bTarget)
                    // FIXED: Removed 'data:' label
                    bus.write(aAddr, val)
                }
                
                if !fixed {
                    if increment { aAddr -= 1 } else { aAddr += 1 }
                }
                count -= 1
            }
        }
        
        // Update registers after transfer
        ch.count = 0
        ch.srcAddr = UInt16(aAddr & 0xFFFF)
        channels[channel] = ch
    }
    
    // MARK: - H-Blank DMA (HDMA)
    
    func enableHDMA(_ mask: UInt8) {
        hdmaEnabled = mask
        for i in 0..<8 {
            if (mask & (1 << i)) != 0 {
                // Initialize HDMA for frame
                channels[i].hdmaActive = true
                channels[i].hdmaDoTransfer = false
                
                // Load address table pointer
                channels[i].indirectAddr = channels[i].hdmaAddr
                channels[i].lineCounter = 0
                channels[i].repeatMode = false
                
                // Load first line
                loadHDMALine(channel: i)
            } else {
                channels[i].hdmaActive = false
            }
        }
    }
    
    func runHDMA() {
        guard hdmaEnabled != 0 else { return }
        
        for i in 0..<8 {
            guard channels[i].hdmaActive else { continue }
            
            // Perform transfer if needed
            if channels[i].hdmaDoTransfer {
                performHDMATransfer(channel: i)
            }
            
            // Decrement line counter
            channels[i].lineCounter = channels[i].lineCounter & 0x7F
            channels[i].lineCounter = channels[i].lineCounter &- 1
            channels[i].hdmaDoTransfer = channels[i].repeatMode
            
            // If counter expires (wrapped or negative), load next entry
            if (channels[i].lineCounter & 0x80) != 0 {
                loadHDMALine(channel: i)
            }
        }
    }
    
    private func loadHDMALine(channel: Int) {
        var ch = channels[channel]
        
        // Read "Line Count" byte from table
        let addr = (UInt32(ch.srcBank) << 16) | UInt32(ch.indirectAddr)
        let lineByte = bus.read(addr)
        ch.indirectAddr &+= 1
        
        if lineByte == 0 {
            // Terminator
            ch.hdmaActive = false
            channels[channel] = ch
            return
        }
        
        ch.repeatMode = (lineByte & 0x80) != 0
        ch.lineCounter = lineByte & 0x7F
        ch.hdmaDoTransfer = true
        
        // Indirect addressing mode support
        if (ch.control & 0x40) != 0 {
            // Fetch indirect address (2 bytes)
            let addrLo = (UInt32(ch.srcBank) << 16) | UInt32(ch.indirectAddr)
            let lo = bus.read(addrLo)
            let hi = bus.read(addrLo + 1)
            ch.indirectAddr &+= 2
            
            // Store target address in count register for indirect mode
            ch.count = (UInt16(hi) << 8) | UInt16(lo)
        }
        
        channels[channel] = ch
    }
    
    private func performHDMATransfer(channel: Int) {
        var ch = channels[channel]
        let mode = ch.control & 0x07
        let indirect = (ch.control & 0x40) != 0
        let bAddr = 0x2100 + UInt16(ch.destReg)
        
        // Source depends on Direct vs Indirect
        var srcBank = ch.srcBank
        var srcAddr = ch.indirectAddr
        
        if indirect {
            srcBank = ch.indirectBank
            srcAddr = ch.count // In indirect mode, `count` holds the address
        }
        
        let pattern = getTransferPattern(mode)
        
        for offset in pattern {
            let fullSrc = (UInt32(srcBank) << 16) | UInt32(srcAddr)
            let val = bus.read(fullSrc)
            // FIXED: Removed 'data:' label
            bus.write(UInt32(bAddr) + UInt32(offset), val)
            
            srcAddr &+= 1
        }
        
        if indirect {
            ch.count = srcAddr // Update indirect pointer
        } else {
            ch.indirectAddr = srcAddr // Update direct table pointer
        }
        
        channels[channel] = ch
    }
    
    // MARK: - Helpers
    
    private func getTransferPattern(_ mode: UInt8) -> [UInt8] {
        switch mode {
        case 0: return [0]
        case 1: return [0, 1]
        case 2: return [0, 0]
        case 3: return [0, 0, 1, 1]
        case 4: return [0, 1, 2, 3]
        case 5: return [0, 1, 0, 1] // Interleaved
        case 6: return [0, 0]       // Same as 2
        case 7: return [0, 0, 1, 1] // Same as 3
        default: return [0]
        }
    }
}
